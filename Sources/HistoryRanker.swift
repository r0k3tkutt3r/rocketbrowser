import Foundation

/// Chooses which of your past URLs deserve to be address-bar suggestions.
///
/// The rule it exists to enforce: a page you visited once and abandoned should not
/// outrank the site itself. It gets there from usage statistics alone — how often, how
/// recently, and how attentively you visited — so it applies equally to a stale chat
/// thread, a one-off search result page, or a deep link someone sent you, without
/// anyone listing those sites anywhere.
enum HistoryRanker {

    struct Candidate: Equatable {
        let url: String
        let host: String
        /// The path shown as the row's subtitle; nil for a bare site.
        let detail: String?
        let score: Double
        let isSiteRoot: Bool
    }

    /// One- and two-letter queries match site names only. Letting them match anywhere
    /// in a URL is what makes typing "c" surface a random page whose path merely
    /// contains a "c".
    static let minimumQueryLengthForPathMatch = 3
    /// A deeper page must have been visited more than once to compete with its site…
    static let minimumVisitsForDeepURL = 2
    /// …and must have held attention at least this long in total.
    static let minimumEngagementForDeepURL: TimeInterval = 15
    /// Visits lose half their weight every two weeks, so abandoned pages fade out.
    static let recencyHalfLifeDays = 14.0

    private struct Stats {
        var visits = 0
        var engagement: TimeInterval = 0
        var frecency = 0.0
        var lastSeen = Date.distantPast
        var host = ""
    }

    static func matches(for query: String, in visits: [Visit], at now: Date = Date(),
                        limit: Int = 4) -> [Candidate] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        let allowPathMatch = needle.count >= minimumQueryLengthForPathMatch

        var byURL: [String: Stats] = [:]
        var byHost: [String: Stats] = [:]

        for visit in visits {
            let ageDays = max(0, now.timeIntervalSince(visit.ts) / 86400)
            let weight = pow(0.5, ageDays / recencyHalfLifeDays)
            // Attention matters, but an unmeasured old visit is not a bounce.
            let attention = visit.hasEngagementData
                ? 0.25 + 0.75 * min(1, visit.engagementSeconds / 120)
                : 0.7

            for key in [visit.url, visit.host] {
                let isHost = key == visit.host
                var stats = isHost ? (byHost[key] ?? Stats()) : (byURL[key] ?? Stats())
                stats.visits += 1
                stats.engagement += visit.engagementSeconds
                stats.frecency += weight * attention
                stats.lastSeen = max(stats.lastSeen, visit.ts)
                stats.host = visit.host
                if isHost { byHost[key] = stats } else { byURL[key] = stats }
            }
        }

        var candidates: [Candidate] = []

        // A matching site always competes, represented by its bare root.
        for (host, stats) in byHost {
            guard let quality = hostMatchQuality(host: host, needle: needle) else { continue }
            candidates.append(Candidate(url: "https://\(host)", host: host, detail: nil,
                                        score: quality * stats.frecency, isSiteRoot: true))
        }

        // Deeper pages only earn a row by being genuinely used.
        for (urlString, stats) in byURL {
            guard let url = URL(string: urlString), let host = url.host else { continue }
            let path = url.path
            guard path.count > 1 || url.query != nil else { continue }   // that is the root
            // A results page is not a destination — you would just search again, and
            // the query it carries is whatever you happened to type that day.
            guard URLDisplay.searchQuery(from: url) == nil else { continue }
            guard stats.visits >= minimumVisitsForDeepURL,
                  stats.engagement >= minimumEngagementForDeepURL else { continue }

            let hostQuality = hostMatchQuality(host: host, needle: needle)
            let pathMatches = allowPathMatch && urlString.lowercased().contains(needle)
            guard hostQuality != nil || pathMatches else { continue }
            // A deep page matched only through its site name starts below that site.
            let quality = pathMatches ? 1.0 : (hostQuality ?? 0) * 0.6
            candidates.append(Candidate(url: urlString, host: host, detail: path,
                                        score: quality * stats.frecency, isSiteRoot: false))
        }

        return candidates
            .sorted { ($0.score, $0.isSiteRoot ? 1 : 0) > ($1.score, $1.isSiteRoot ? 1 : 0) }
            .prefix(limit)
            .map { $0 }
    }

    /// Prefix matches beat mid-name matches: typing "goo" means google, not "gogoo".
    /// Weaker kinds of match need a longer query to count, because on one letter they
    /// match nearly everything — which is how a single "c" pulled in unrelated sites.
    private static func hostMatchQuality(host: String, needle: String) -> Double? {
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if bare.hasPrefix(needle) { return 1.0 }

        // Match the start of an inner label, so "git" finds "docs.github.com". The
        // trailing public suffix is skipped: otherwise "c" matches every .com there is.
        if needle.count >= 2 {
            for label in bare.split(separator: ".").dropLast() where label.hasPrefix(needle) {
                return 0.75
            }
        }
        // Matching mid-word is the weakest signal, so it needs a real query behind it.
        if needle.count >= minimumQueryLengthForPathMatch, bare.contains(needle) { return 0.4 }
        return nil
    }
}
