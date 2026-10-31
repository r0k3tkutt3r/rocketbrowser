// swift-tools-version: 5.9
// rocket-speech: the Read Aloud engine, built by build.sh into
// Rocket.app/Contents/Helpers/RocketSpeech/. It is the one place Rocket takes a
// third-party package, and it is a separate process on purpose: the app itself stays a
// dependency-free swiftc build, and quitting the helper is how its ~350 MB is returned.
//
// kokoro-coreml (Apache-2.0) is Kokoro-82M split across the Neural Engine, GPU and CPU.
// Pinned by commit because its model bundles carry a manifest schema that older and
// newer SDK commits reject.
import PackageDescription

let package = Package(
    name: "RocketSpeech",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/mattmireles/kokoro-coreml",
                 revision: "9092bc88e505d8b17eab6403dd032fe5c190454d"),
    ],
    targets: [
        .executableTarget(
            name: "rocket-speech",
            dependencies: [.product(name: "KokoroTTS", package: "kokoro-coreml")],
            path: "Sources"
        ),
    ]
)
