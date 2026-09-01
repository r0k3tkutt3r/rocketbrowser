import Foundation

/// Turns the flat visit log into the rows the history window draws: date headers
/// interleaved with visits, newest first, optionally filtered by a search string.
///
/// Pure and calendar-aware, so it can be tested against fixed dates without a UI.
enum HistoryGrouping {

    enum Row: Equatable {
        case header(String)
        case visit(Visit)
    }

    /// Beyond this many days back, headers show a date instead of a weekday name —
    /// "Tuesday" stops being useful once there is more than one Tuesday in view.
    static let weekdayNameWindowDays = 7

    /// Matches a visit against a search string. Deliberately a plain substring test
    /// over title, URL and host rather than `HistoryRanker`: the ranker suppresses
    /// one-off deep URLs, which is exactly what this window exists to surface.
    static func matches(_ visit: Visit, query: String) -> Bool {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return visit.displayTitle.lowercased().contains(needle)
            || visit.url.lowercased().contains(needle)
            || visit.host.lowercased().contains(needle)
    }

    static func rows(for visits: [Visit], query: String = "", now: Date = Date(),
                     calendar: Calendar = .current) -> [Row] {
        let matching = visits
            .filter { matches($0, query: query) }
            .sorted { $0.ts > $1.ts }

        var rows: [Row] = []
        var currentDay: Date?
        for visit in matching {
            let day = calendar.startOfDay(for: visit.ts)
            if day != currentDay {
                rows.append(.header(headerTitle(for: day, now: now, calendar: calendar)))
                currentDay = day
            }
            rows.append(.visit(visit))
        }
        return rows
    }

    /// "Today" / "Yesterday" / "Tuesday" within the last week / "12 August 2026".
    /// A visit stamped in the future (clock change, imported data) still needs a
    /// header, so anything newer than today is grouped under Today.
    static func headerTitle(for day: Date, now: Date, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let daysBack = calendar.dateComponents([.day], from: day, to: today).day ?? 0

        if daysBack <= 0 { return "Today" }
        if daysBack == 1 { return "Yesterday" }
        if daysBack < weekdayNameWindowDays {
            let formatter = makeFormatter(calendar)
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: day)
        }
        let formatter = makeFormatter(calendar)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }

    /// The time shown at the right of each row.
    static func timeLabel(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = makeFormatter(calendar)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Setting `calendar` alone is not enough: `DateFormatter` keeps its own time zone
    /// and falls back to the system's, so a formatter built from a UTC calendar would
    /// still render local days. That agrees with the calendar by luck in the app (both
    /// default to the system zone) and disagrees the moment a caller passes any other
    /// one — which is exactly what the tests do.
    private static func makeFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return formatter
    }

    /// The row's secondary line: the search terms for a results page, otherwise the
    /// host and path. Reuses `URLDisplay` so the window and the address bar agree
    /// about what a URL means.
    static func subtitle(for visit: Visit) -> String {
        guard let url = URL(string: visit.url) else { return visit.host }
        if let query = URLDisplay.searchQuery(from: url) {
            return "\(URLDisplay.rootDomain(visit.host)) — \(query)"
        }
        let path = url.path
        return path.isEmpty || path == "/" ? visit.host : visit.host + path
    }
}
