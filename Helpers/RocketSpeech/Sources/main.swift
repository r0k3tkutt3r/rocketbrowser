import CryptoKit
import Foundation
import KokoroTTS

// Protocol, one JSON object per line both ways.
//   stdin:  {"id": Int, "text": String, "voice": String?}
//           — a new request cancels the one in flight; empty text only cancels.
//   stdout: {"progress": Double}           — first-run model download, 0…1
//           {"id": Int, "pcm": base64}     — Float32 little-endian, 24 kHz mono
//           {"id": Int, "done": true}
//           {"id": Int, "error": String}
// The helper exits when stdin closes, which is how Rocket frees the model.

struct Request: Decodable {
    let id: Int
    let text: String
    var voice: String?
}

/// Voices beyond the starter bundle's af_heart, as listed in the hosted *full* bundle's
/// manifest at the same Hugging Face revision. The full bundle is 2.3 GB, almost all of
/// it model buckets Rocket never uses; a voice is one 510 KB file.
let extraVoices: [(name: String, bytes: Int, sha256: String)] = [
    ("am_michael", 522_240, "1d1f21dd8da39c30705cd4c75d039d265e9bc4a2a93ed09bc9e1b1225eb95ba1"),
]

/// The starter bundle plus `extraVoices`, as a sibling directory of hard links.
///
/// The SDK refuses any voice its KokoroRuntimeManifest.json does not list, and that
/// file cannot be edited in place: every launch re-verifies it against the pinned
/// hosted manifest and would re-download it. Symlinks are refused too
/// (KokoroPathGuard), hence hard links — zero extra disk, and still regular files.
/// The compiled-model cache stays the starter's, so nothing is compiled twice.
func withExtraVoices(_ starter: KokoroResourceProvider) async throws -> KokoroResourceProvider {
    guard case .downloadedDirectory(let root, let compiled) = starter else { return starter }
    let fm = FileManager.default
    let bundle = root.deletingLastPathComponent().appendingPathComponent("kokoro-coreml-rocket")
    let starterManifest = try Data(contentsOf: root.appendingPathComponent("KokoroRuntimeManifest.json"))
    let stamp = bundle.appendingPathComponent("starter-manifest.json")
    // Rebuilt whenever the starter bundle changes underneath it.
    if (try? Data(contentsOf: stamp)) != starterManifest {
        try? fm.removeItem(at: bundle)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(atPath: root.path)
        where item != compiled.lastPathComponent && item != "KokoroRuntimeManifest.json" && !item.hasPrefix(".") {
            try fm.linkItem(at: root.appendingPathComponent(item), to: bundle.appendingPathComponent(item))
        }
        var manifest = try JSONSerialization.jsonObject(with: starterManifest) as! [String: Any]
        var voices = manifest["voices"] as? [[String: Any]] ?? []
        for voice in extraVoices {
            let url = URL(string: "https://huggingface.co/\(KokoroHostedModels.repoID)/resolve/"
                + "\(KokoroHostedModels.revision)/voices/\(voice.name).bin")!
            let (data, _) = try await URLSession.shared.data(from: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == voice.bytes, digest == voice.sha256 else {
                throw NSError(domain: "rocket-speech", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "\(voice.name) failed its hash check"])
            }
            try data.write(to: bundle.appendingPathComponent("voices/\(voice.name).bin"))
            voices.append(["path": "voices/\(voice.name).bin", "bytes": voice.bytes, "sha256": voice.sha256])
        }
        manifest["voices"] = voices
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: bundle.appendingPathComponent("KokoroRuntimeManifest.json"))
        try starterManifest.write(to: stamp)   // last: a half-built bundle is rebuilt
    }
    return .directory(bundle, compiledModelsDirectory: compiled)
}

final class Output: @unchecked Sendable {
    private let lock = NSLock()

    func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(data)
    }
}

let output = Output()

actor Speaker {
    private var loading: Task<KokoroTTS, Error>?

    /// Loaded once and kept warm: Core ML specialises each model on its first
    /// prediction, so the second request is the fast one.
    private func engine() async throws -> KokoroTTS {
        if let loading { return try await loading.value }
        let task = Task {
            let starter = try await KokoroResourceProvider.huggingFace(progress: { progress in
                if progress.phase == .downloading { output.send(["progress": progress.fraction]) }
            })
            return try await KokoroTTS.load(resources: withExtraVoices(starter))
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil   // a failed download is retried by the next request
            throw error
        }
    }

    func speak(_ request: Request) async {
        do {
            let tts = try await engine()
            try Task.checkCancellation()
            let voice = request.voice.map { KokoroVoiceID($0) } ?? .afHeart
            try await tts.synthesizeStreaming(request.text, voice: voice) { audio in
                let pcm = audio.samples.withUnsafeBytes { Data($0) }
                output.send(["id": request.id, "pcm": pcm.base64EncodedString()])
            }
            output.send(["id": request.id, "done": true])
        } catch {
            // Rocket already moved on from a cancelled request; it ignores stale ids anyway.
            guard !Task.isCancelled else { return }
            output.send(["id": request.id, "error": String(describing: error)])
        }
    }
}

let speaker = Speaker()
var current: Task<Void, Never>?
while let line = readLine() {
    guard let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else { continue }
    current?.cancel()
    current = nil
    guard !request.text.isEmpty else { continue }
    // Detached: this loop blocks the main thread in readLine.
    current = Task.detached { await speaker.speak(request) }
}
