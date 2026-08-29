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

    /// A model saved before the feature set changed still loads and still predicts —
    /// the extra inputs are simply ignored by its narrower first layer — but it cannot
    /// use them, so it is retrained at the first opportunity rather than left stale.
    var modelMatchesCurrentFeatures: Bool {
        guard let model else { return false }
        return model.mlp.inputSize == 11 + model.vocab.count
    }

    /// Retrains at most once per day — but keeps trying on every call until the
    /// first model exists, so suggestions appear as soon as there's enough history
    /// rather than after the next day boundary. Called at launch and on activation.
    func retrainIfDue(completion: ((Bool) -> Void)? = nil) {
        guard isEnabled else {
            completion?(false)
            return
        }
        let last = UserDefaults.standard.object(forKey: "SuggestionsLastTrained") as? Date
        if model == nil || !modelMatchesCurrentFeatures
            || last == nil || !Calendar.current.isDateInToday(last!) {
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
        let context = Self.context(from: HistoryStore.shared.visits, at: date)
        return Self.predict(model: model, at: date, excluded: excluded,
                            count: count, context: context)
    }

    // MARK: - Pure training/inference (testable)

    /// A visit starts a new browsing session when this much time passed since the last
    /// one — the gap that separates "sat down at the Mac" from "still browsing".
    static let sessionGap: TimeInterval = 30 * 60
    /// Attention past this point counts as full engagement.
    private static let fullEngagementSeconds: TimeInterval = 120

    /// Everything the model needs about "right now" that is not the clock.
    struct PredictionContext {
        var previousHost: String?
        var isSessionStart: Bool
        /// Per-host multiplier: >1 when a site is overdue, <1 when you just left it.
        var dueness: [String: Double] = [:]
    }

    /// Input layout: day-of-week one-hot (7) + cyclical time of day (2) + weekend (1)
    /// + session-start (1) + previous-host one-hot (vocab). The previous-host block is
    /// what lets the net learn transitions — that mail is usually followed by calendar.
    static func features(for date: Date, sessionStart: Bool,
                         previousHostIndex: Int?, vocabSize: Int) -> [Double] {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date) - 1  // 0 = Sunday
        var features = [Double](repeating: 0, count: 11 + vocabSize)
        features[weekday] = 1
        let hour = Double(calendar.component(.hour, from: date))
            + Double(calendar.component(.minute, from: date)) / 60
        features[7] = sin(2 * .pi * hour / 24)
        features[8] = cos(2 * .pi * hour / 24)
        features[9] = (weekday == 0 || weekday == 6) ? 1 : 0
        features[10] = sessionStart ? 1 : 0
        if let previousHostIndex, previousHostIndex < vocabSize {
            features[11 + previousHostIndex] = 1
        }
        return features
    }

    /// How much a visit counts for. A two-second bounce still says something, but a
    /// page you actually read says a great deal more. Visits from before attention
    /// tracking existed score neutrally rather than as bounces — "not measured" must
    /// not be read as "not engaged", or upgrading the browser would throw away the
    /// history the model was already built on.
    static func engagementWeight(_ visit: Visit) -> Double {
        guard visit.hasEngagementData else { return 0.7 }
        return 0.25 + 0.75 * min(1, visit.engagementSeconds / fullEngagementSeconds)
    }

    static func trainModel(visits: [Visit], excluded: Set<String>, now: Date) -> TrainedModel? {
        let usable = visits.filter { !excluded.contains($0.host) }
        guard usable.count >= 25 else { return nil }

        // Vocabulary: recency-weighted AND engagement-weighted, so sites you linger on
        // outrank sites you merely pass through often.
        var weightedCounts: [String: Double] = [:]
        for visit in usable {
            let ageDays = now.timeIntervalSince(visit.ts) / 86400
            weightedCounts[visit.host, default: 0] += pow(0.5, ageDays / 14) * engagementWeight(visit)
        }
        let vocab = weightedCounts
            .filter { $0.value >= 1.0 }
            .sorted { $0.value > $1.value }
            .prefix(24)
            .map(\.key)
        guard vocab.count >= 3 else { return nil }
        let indexOf = Dictionary(uniqueKeysWithValues: vocab.enumerated().map { ($1, $0) })

        // Chronological order is what makes "previous host" and "session start" mean
        // anything, so sort before walking the list.
        let ordered = usable.sorted { $0.ts < $1.ts }
        var inputs: [[Double]] = []
        var labels: [Int] = []
        var sampleWeights: [Double] = []

        for (position, visit) in ordered.enumerated() {
            guard let label = indexOf[visit.host] else { continue }
            let previous = position > 0 ? ordered[position - 1] : nil
            let gap = previous.map { visit.ts.timeIntervalSince($0.ts) } ?? .greatestFiniteMagnitude
            let sessionStart = gap >= sessionGap
            // Only a same-session predecessor is context; across a session boundary the
            // previous page tells you nothing about this one.
            let previousIndex = sessionStart ? nil : previous.flatMap { indexOf[$0.host] }

            inputs.append(features(for: visit.ts, sessionStart: sessionStart,
                                   previousHostIndex: previousIndex, vocabSize: vocab.count))
            labels.append(label)
            let ageDays = now.timeIntervalSince(visit.ts) / 86400
            sampleWeights.append(pow(0.5, ageDays / 14) * engagementWeight(visit))
        }
        guard inputs.count >= 20 else { return nil }

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

    /// Builds "right now" from live history: what you were last on, whether this is a
    /// fresh session, and which sites are overdue relative to their own rhythm.
    static func context(from visits: [Visit], at date: Date) -> PredictionContext {
        let ordered = visits.sorted { $0.ts < $1.ts }
        guard let last = ordered.last else {
            return PredictionContext(previousHost: nil, isSessionStart: true)
        }
        let sessionStart = date.timeIntervalSince(last.ts) >= sessionGap

        // Typical gap between visits to each host, so "overdue" is judged against that
        // site's own rhythm — hourly for a dashboard, daily for a news site.
        var timestamps: [String: [Date]] = [:]
        for visit in ordered { timestamps[visit.host, default: []].append(visit.ts) }

        var dueness: [String: Double] = [:]
        for (host, stamps) in timestamps {
            guard let lastVisit = stamps.last else { continue }
            let sinceLast = date.timeIntervalSince(lastVisit)
            guard stamps.count >= 3 else {
                dueness[host] = 1
                continue
            }
            let gaps = zip(stamps.dropFirst(), stamps).map { $0.timeIntervalSince($1) }
                .filter { $0 > 60 }.sorted()
            guard !gaps.isEmpty else {
                dueness[host] = 1
                continue
            }
            let typical = gaps[gaps.count / 2]
            // Just left it → damp it down; long overdue → lift it up.
            dueness[host] = min(1.6, max(0.3, sinceLast / typical))
        }
        return PredictionContext(previousHost: sessionStart ? nil : last.host,
                                 isSessionStart: sessionStart,
                                 dueness: dueness)
    }

    static func predict(model: TrainedModel, at date: Date, excluded: Set<String>,
                        count: Int, context: PredictionContext = PredictionContext(
                            previousHost: nil, isSessionStart: true)) -> [Suggestion] {
        let previousIndex = context.previousHost.flatMap { model.vocab.firstIndex(of: $0) }
        let probs = model.mlp.forward(features(for: date, sessionStart: context.isSessionStart,
                                               previousHostIndex: previousIndex,
                                               vocabSize: model.vocab.count))
        let floor = 0.5 / Double(model.vocab.count)
        return zip(model.vocab, probs)
            .filter { !excluded.contains($0.0) && $0.1 > floor }
            // Never suggest the page you are already coming from.
            .filter { $0.0 != context.previousHost }
            .map { (host: $0.0, score: $0.1 * (context.dueness[$0.0] ?? 1)) }
            .sorted { $0.score > $1.score }
            .prefix(count)
            .map { Suggestion(host: $0.host, url: model.openURLs[$0.host] ?? "https://\($0.host)",
                              score: $0.score) }
    }
}
