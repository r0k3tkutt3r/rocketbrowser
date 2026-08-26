import Foundation

/// A tiny multilayer perceptron (input → ReLU hidden → softmax), trained with plain
/// SGD. ~1,300 parameters at most — training on a full history takes well under a
/// second and inference is a few thousand multiplies.
struct TinyMLP: Codable {
    var w1: [Double]   // hidden × input, flattened
    var b1: [Double]
    var w2: [Double]   // output × hidden, flattened
    var b2: [Double]
    var inputSize: Int
    var hiddenSize: Int
    var outputSize: Int

    func forward(_ x: [Double]) -> [Double] {
        var hidden = [Double](repeating: 0, count: hiddenSize)
        for j in 0..<hiddenSize {
            var sum = b1[j]
            let base = j * inputSize
            for i in 0..<inputSize { sum += w1[base + i] * x[i] }
            hidden[j] = max(0, sum)
        }
        var out = [Double](repeating: 0, count: outputSize)
        for k in 0..<outputSize {
            var sum = b2[k]
            let base = k * hiddenSize
            for j in 0..<hiddenSize { sum += w2[base + j] * hidden[j] }
            out[k] = sum
        }
        return Self.softmax(out)
    }

    static func softmax(_ values: [Double]) -> [Double] {
        let maxValue = values.max() ?? 0
        let exps = values.map { exp($0 - maxValue) }
        let total = exps.reduce(0, +)
        return exps.map { $0 / total }
    }

    static func trained(inputs: [[Double]], labels: [Int], sampleWeights: [Double],
                        hidden: Int, classes: Int) -> TinyMLP {
        let input = inputs[0].count
        var rng = SystemRandomNumberGenerator()
        var mlp = TinyMLP(
            w1: (0..<(hidden * input)).map { _ in Double.random(in: -0.3...0.3, using: &rng) },
            b1: [Double](repeating: 0, count: hidden),
            w2: (0..<(classes * hidden)).map { _ in Double.random(in: -0.3...0.3, using: &rng) },
            b2: [Double](repeating: 0, count: classes),
            inputSize: input, hiddenSize: hidden, outputSize: classes)

        var learningRate = 0.08
        var order = Array(inputs.indices)
        for _ in 0..<80 {
            order.shuffle(using: &rng)
            for sample in order {
                mlp.step(x: inputs[sample], label: labels[sample],
                         lr: learningRate * sampleWeights[sample])
            }
            learningRate *= 0.97
        }
        return mlp
    }

    private mutating func step(x: [Double], label: Int, lr: Double) {
        // Forward
        var hidden = [Double](repeating: 0, count: hiddenSize)
        for j in 0..<hiddenSize {
            var sum = b1[j]
            let base = j * inputSize
            for i in 0..<inputSize { sum += w1[base + i] * x[i] }
            hidden[j] = max(0, sum)
        }
        var out = [Double](repeating: 0, count: outputSize)
        for k in 0..<outputSize {
            var sum = b2[k]
            let base = k * hiddenSize
            for j in 0..<hiddenSize { sum += w2[base + j] * hidden[j] }
            out[k] = sum
        }
        let probs = Self.softmax(out)

        // Backward (cross-entropy + softmax)
        var gradOut = probs
        gradOut[label] -= 1
        var gradHidden = [Double](repeating: 0, count: hiddenSize)
        for k in 0..<outputSize {
            let base = k * hiddenSize
            let g = gradOut[k]
            for j in 0..<hiddenSize {
                gradHidden[j] += g * w2[base + j]
                w2[base + j] -= lr * g * hidden[j]
            }
            b2[k] -= lr * g
        }
        for j in 0..<hiddenSize where hidden[j] > 0 {
            let base = j * inputSize
            let g = gradHidden[j]
            for i in 0..<inputSize { w1[base + i] -= lr * g * x[i] }
            b1[j] -= lr * g
        }
    }
}

/// Learns which sites you visit at which day/time from local history and suggests a
/// few on the new tab page. Fully local: history, model, and training never leave disk.
final class SuggestionEngine {

    static let shared = SuggestionEngine()

    struct Suggestion {
        let host: String
        let url: String
        let score: Double
    }

    struct TrainedModel: Codable {
        var vocab: [String]
        var openURLs: [String: String]
        var mlp: TinyMLP
        var trainedAt: Date
    }

    private(set) var model: TrainedModel?
    private let queue = DispatchQueue(label: "rocket.suggestions", qos: .utility)

    private static var modelFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Rocket", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("suggestions.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.modelFileURL),
           let decoded = try? JSONDecoder().decode(TrainedModel.self, from: data) {
            model = decoded
        }
    }

    // MARK: - Settings

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "SuggestionsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "SuggestionsEnabled") }
    }

    var excludedHosts: [String] {
        UserDefaults.standard.stringArray(forKey: "SuggestionsExcludedHosts") ?? []
    }

    /// Hosts the browser worked out are waypoints (sign-in hops, shorteners) rather
    /// than places you visit. Recomputed from history, never persisted, never hardcoded.
    var autoExcludedHosts: Set<String> {
        WaypointDetector.waypointHosts(in: HistoryStore.shared.visits)
    }

    /// Auto-excluded hosts with the reason each one was flagged, for display.
    var autoExclusionReasons: [(host: String, reason: String)] {
        WaypointDetector.analyze(HistoryStore.shared.visits)
            .filter(\.isWaypoint)
            .map { ($0.host, $0.reason) }
    }

    func excludeHost(_ host: String) {
        var hosts = excludedHosts
        guard !hosts.contains(host) else { return }
        hosts.append(host)
        UserDefaults.standard.set(hosts, forKey: "SuggestionsExcludedHosts")
        retrain()
    }

    func includeHost(_ host: String) {
        let hosts = excludedHosts.filter { $0 != host }
        UserDefaults.standard.set(hosts, forKey: "SuggestionsExcludedHosts")
        retrain()
    }

    // MARK: - Lifecycle

    /// Retrains at most once per day — but keeps trying on every call until the
    /// first model exists, so suggestions appear as soon as there's enough history
    /// rather than after the next day boundary. Called at launch and on activation.
    func retrainIfDue(completion: ((Bool) -> Void)? = nil) {
        guard isEnabled else {
            completion?(false)
            return
        }
        let last = UserDefaults.standard.object(forKey: "SuggestionsLastTrained") as? Date
        if model == nil || last == nil || !Calendar.current.isDateInToday(last!) {
            retrain(completion: completion)
        } else {
            completion?(false)
        }
    }

    func retrain(completion: ((Bool) -> Void)? = nil) {
        guard isEnabled else {
            completion?(false)
            return
        }
        let visits = HistoryStore.shared.visits
        let excluded = Set(excludedHosts).union(WaypointDetector.waypointHosts(in: visits))
        queue.async {
            let trained = Self.trainModel(visits: visits, excluded: excluded, now: Date())
            DispatchQueue.main.async {
                if let trained {
                    self.model = trained
                    if let data = try? JSONEncoder().encode(trained) {
                        try? data.write(to: Self.modelFileURL, options: .atomic)
                    }
                    // Only stamp on success — a failed (not-enough-data) attempt must
                    // not block retrying later the same day.
                    UserDefaults.standard.set(Date(), forKey: "SuggestionsLastTrained")
                }
                completion?(trained != nil)
            }
        }
    }

    func reset() {
        HistoryStore.shared.clear()
        model = nil
        try? FileManager.default.removeItem(at: Self.modelFileURL)
        UserDefaults.standard.removeObject(forKey: "SuggestionsLastTrained")
    }

    func suggestions(count: Int = 5, at date: Date = Date()) -> [Suggestion] {
        guard isEnabled, let model else { return [] }
        let excluded = Set(excludedHosts).union(autoExcludedHosts)
        return Self.predict(model: model, at: date, excluded: excluded, count: count)
    }

    // MARK: - Pure training/inference (testable)

    /// Day-of-week one-hot (7) + cyclical time of day (2) + weekend flag (1).
    static func features(for date: Date) -> [Double] {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date) - 1  // 0 = Sunday
        var features = [Double](repeating: 0, count: 10)
        features[weekday] = 1
        let hour = Double(calendar.component(.hour, from: date))
            + Double(calendar.component(.minute, from: date)) / 60
        features[7] = sin(2 * .pi * hour / 24)
        features[8] = cos(2 * .pi * hour / 24)
        features[9] = (weekday == 0 || weekday == 6) ? 1 : 0
        return features
    }

    static func trainModel(visits: [Visit], excluded: Set<String>, now: Date) -> TrainedModel? {
        let usable = visits.filter { !excluded.contains($0.host) }
        guard usable.count >= 25 else { return nil }

        // Vocabulary: most-visited hosts, recency-weighted, one-off sites dropped.
        var weightedCounts: [String: Double] = [:]
        for visit in usable {
            let ageDays = now.timeIntervalSince(visit.ts) / 86400
            weightedCounts[visit.host, default: 0] += pow(0.5, ageDays / 14)
        }
        let vocab = weightedCounts
            .filter { $0.value >= 1.5 }
            .sorted { $0.value > $1.value }
            .prefix(24)
            .map(\.key)
        guard vocab.count >= 3 else { return nil }
        let indexOf = Dictionary(uniqueKeysWithValues: vocab.enumerated().map { ($1, $0) })

        var inputs: [[Double]] = []
        var labels: [Int] = []
        var sampleWeights: [Double] = []
        for visit in usable {
            guard let label = indexOf[visit.host] else { continue }
            inputs.append(features(for: visit.ts))
            labels.append(label)
            let ageDays = now.timeIntervalSince(visit.ts) / 86400
            sampleWeights.append(pow(0.5, ageDays / 14))
        }

        let mlp = TinyMLP.trained(inputs: inputs, labels: labels, sampleWeights: sampleWeights,
                                  hidden: 16, classes: vocab.count)

        var openURLs: [String: String] = [:]
        for visit in usable.reversed() where openURLs[visit.host] == nil {
            if let url = URL(string: visit.url), let scheme = url.scheme, let host = url.host {
                openURLs[visit.host] = "\(scheme)://\(host)"
            }
        }
        return TrainedModel(vocab: Array(vocab), openURLs: openURLs, mlp: mlp, trainedAt: now)
    }

    static func predict(model: TrainedModel, at date: Date,
                        excluded: Set<String>, count: Int) -> [Suggestion] {
        let probs = model.mlp.forward(features(for: date))
        let floor = 0.5 / Double(model.vocab.count)
        return zip(model.vocab, probs)
            .filter { !excluded.contains($0.0) && $0.1 > floor }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map { Suggestion(host: $0.0, url: model.openURLs[$0.0] ?? "https://\($0.0)", score: $0.1) }
    }
}
