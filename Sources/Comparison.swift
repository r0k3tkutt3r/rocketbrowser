import Foundation
import WebKit

/// Price comparisons: several watched values that mean the same thing on different
/// sites, ordered cheapest first.
///
/// A comparison is nothing but a name shared by several `PageWatch`es. The selector
/// capture, the background recheck, the change detection and the storage are all the
/// watch machinery already in place — this adds an ordering, a page that renders it,
/// and the one piece of news a lone watch cannot carry: the cheapest one changed hands.
enum Comparison {

    struct Group: Equatable {
        let name: String
        /// Cheapest first; entries whose value does not read as a number sort last.
        let items: [PageWatch]

        /// Nil for a comparison of things that are not numbers ("In stock" against
        /// "Sold out") — those are still worth lining up, they just have no cheapest.
        var lowest: PageWatch? { items.first { WatchValue.number(from: $0.value) != nil } }
    }

    // MARK: - Grouping

    static func groups(in watches: [PageWatch]) -> [Group] {
        let named = watches.compactMap { watch -> (name: String, watch: PageWatch)? in
            guard let name = watch.comparison, !name.isEmpty else { return nil }
            return (name, watch)
        }
        return Dictionary(grouping: named, by: \.name)
            .map { Group(name: $0.key, items: sorted($0.value.map(\.watch))) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func group(named name: String, in watches: [PageWatch]) -> Group? {
        groups(in: watches).first { $0.name == name }
    }

    static func names(in watches: [PageWatch]) -> [String] { groups(in: watches).map(\.name) }

    /// Cheapest first. Anything that is not a number keeps its existing order behind
    /// the numbers rather than being dropped: a comparison whose values stop parsing
    /// after a site redesign should look wrong, not look empty.
    static func sorted(_ items: [PageWatch]) -> [PageWatch] {
        items.enumerated().sorted { left, right in
            let a = WatchValue.number(from: left.element.value)
            let b = WatchValue.number(from: right.element.value)
            switch (a, b) {
            case let (a?, b?): return a == b ? left.offset < right.offset : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left.offset < right.offset
            }
        }.map(\.element)
    }

    /// How much more this entry costs than the cheapest one. Nil for the cheapest
    /// itself, and for anything that is not a number.
    static func premium(of item: PageWatch, in group: Group) -> Double? {
        guard let lowest = group.lowest, lowest.id != item.id,
              let best = WatchValue.number(from: lowest.value),
              let value = WatchValue.number(from: item.value), value > best else { return nil }
        return value - best
    }

    // MARK: - The page

    static var pageFileURL: URL { NewTabPage.directory.appendingPathComponent("compare.html") }

    static func isComparisonURL(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        return url.standardizedFileURL.path == pageFileURL.standardizedFileURL.path
    }

    /// Writes the page and loads it. Regenerating on every open is the whole update
    /// story: the file is a rendering of the store, never a second copy of it.
    static func open(in webView: WKWebView) {
        let html = page(for: groups(in: PageWatchStore.shared.watches))
        try? html.data(using: .utf8)?.write(to: pageFileURL, options: .atomic)
        webView.loadFileURL(pageFileURL, allowingReadAccessTo: NewTabPage.directory)
    }

    static func page(for groups: [Group], now: Date = Date()) -> String {
        let relative = RelativeDateTimeFormatter()
        let body = groups.isEmpty ? emptyState : groups.map { section(for: $0, relative: relative, now: now) }.joined()
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <title>Compare</title>
        <style>
            :root { color-scheme: light dark; --card: #fff; --line: rgba(0,0,0,.10); --dim: #6b6b76; --best: #128a4a; }
            @media (prefers-color-scheme: dark) {
                :root { --card: #1c1c22; --line: rgba(255,255,255,.12); --dim: #9a9aa6; --best: #4fd18b; }
            }
            body { margin: 0; padding: 32px 20px 64px; background: Canvas; color: CanvasText;
                   font: 14px -apple-system, sans-serif; }
            main { max-width: 720px; margin: 0 auto; }
            header { display: flex; align-items: baseline; gap: 12px; margin-bottom: 26px; }
            h1 { font-size: 26px; font-weight: 700; margin: 0; letter-spacing: -.4px; }
            #refresh { margin-left: auto; font: inherit; font-size: 12px; padding: 5px 12px;
                       border-radius: 999px; border: 1px solid var(--line); background: var(--card);
                       color: inherit; cursor: pointer; }
            #refresh:disabled { opacity: .5; cursor: default; }
            h2 { font-size: 15px; font-weight: 600; margin: 30px 0 10px; }
            h2 .sub { font-weight: 400; color: var(--dim); font-size: 13px; margin-left: 8px; }
            ol { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
            li { display: flex; align-items: stretch; background: var(--card);
                 border: 1px solid var(--line); border-radius: 12px; overflow: hidden; }
            li.best { border-color: var(--best); }
            a { flex: 1; display: block; padding: 12px 14px; text-decoration: none; color: inherit; }
            a:hover { background: rgba(127,127,127,.08); }
            .value { font-size: 19px; font-weight: 650; letter-spacing: -.3px;
                     font-variant-numeric: tabular-nums; }
            li.best .value { color: var(--best); }
            .tag { font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: .6px;
                   vertical-align: 3px; margin-left: 8px; color: var(--best); }
            .plus { font-size: 12px; font-weight: 500; color: var(--dim); margin-left: 8px;
                    vertical-align: 2px; }
            .name { margin-top: 3px; font-size: 13px; overflow: hidden; text-overflow: ellipsis;
                    white-space: nowrap; }
            .meta { margin-top: 3px; font-size: 12px; color: var(--dim); }
            .down { color: var(--best); }
            .up { color: #d1443c; }
            .remove { width: 38px; border: 0; border-left: 1px solid var(--line); background: none;
                      color: var(--dim); font-size: 13px; cursor: pointer; }
            .remove:hover { background: rgba(127,127,127,.10); color: inherit; }
            .empty { color: var(--dim); line-height: 1.6; }
            code { background: rgba(127,127,127,.14); padding: 1px 5px; border-radius: 4px; }
        </style>
        </head>
        <body>
        <main>
        <header><h1>Compare</h1><button id="refresh">Check all now</button></header>
        \(body)
        </main>
        <script>
            function post(body) {
                try { window.webkit.messageHandlers.rocket.postMessage(body); } catch (e) { return false; }
                return true;
            }
            const refresh = document.getElementById('refresh');
            refresh.addEventListener('click', function () {
                if (!post({ action: 'checkComparisons' })) { return; }
                refresh.disabled = true;
                refresh.textContent = 'Checking…';
                // Rocket rewrites and reloads this page as each check lands. If nothing
                // is due to change, put the button back rather than leaving it spinning.
                setTimeout(function () { refresh.disabled = false; refresh.textContent = 'Check all now'; }, 20000);
            });
            document.querySelectorAll('.remove').forEach(function (button) {
                button.addEventListener('click', function () {
                    post({ action: 'removeComparisonItem', id: button.dataset.id });
                });
            });
        </script>
        </body>
        </html>
        """
    }

    private static let emptyState = """
    <p class="empty">Nothing to compare yet.<br>
    Select a price on any page, then choose <code>Tools ▸ Compare ▸ Add This Value…</code>
    and give the comparison a name. Add the same name on another site and they line up
    here, cheapest first.</p>
    """

    private static func section(for group: Group, relative: RelativeDateTimeFormatter, now: Date) -> String {
        let subtitle: String
        if let lowest = group.lowest {
            subtitle = "\(group.items.count) item\(group.items.count == 1 ? "" : "s") · cheapest \(lowest.value)"
        } else {
            subtitle = "\(group.items.count) item\(group.items.count == 1 ? "" : "s")"
        }
        let rows = group.items.map { row(for: $0, in: group, relative: relative, now: now) }.joined()
        return """
        <h2>\(escaped(group.name))<span class="sub">\(escaped(subtitle))</span></h2>
        <ol>\(rows)</ol>
        """
    }

    private static func row(for item: PageWatch, in group: Group,
                            relative: RelativeDateTimeFormatter, now: Date) -> String {
        let isBest = group.lowest?.id == item.id
        var value = "<span class=\"value\">\(escaped(item.value))</span>"
        if isBest { value += "<span class=\"tag\">Lowest</span>" }
        if let premium = Comparison.premium(of: item, in: group) {
            value += "<span class=\"plus\">+\(escaped(format(premium)))</span>"
        }

        var meta: [String] = [escaped(item.host)]
        if item.missingSince != nil {
            meta.append("couldn’t find this value")
        } else if let previous = item.previousValue {
            let change = WatchValue.compare(old: previous, new: item.value)
            let style = { () -> String in
                switch change {
                case .decreased: return "down"
                case .increased: return "up"
                default: return ""
                }
            }()
            let marker = WatchValue.marker(for: change) ?? "•"
            meta.append("<span class=\"\(style)\">\(marker) was \(escaped(previous))</span>")
        }
        if let checked = item.checkedAt {
            meta.append(escaped("checked " + relative.localizedString(for: checked, relativeTo: now)))
        }

        return """
        <li class="\(isBest ? "best" : "")">
          <a href="\(attribute(item.url))">
            <div>\(value)</div>
            <div class="name">\(escaped(item.title))</div>
            <div class="meta">\(meta.joined(separator: " · "))</div>
          </a>
          <button class="remove" data-id="\(attribute(item.id.uuidString))" title="Remove from comparison">✕</button>
        </li>
        """
    }

    /// Two decimals unless the difference is whole money.
    static func format(_ amount: Double) -> String {
        amount == amount.rounded() ? String(Int(amount)) : String(format: "%.2f", amount)
    }

    private static func escaped(_ text: String) -> String { htmlEscaped(text) }

    /// Attribute values need the quotes escaped too — a page title is written by the
    /// site, and `htmlEscaped` alone would let one break out of an attribute.
    private static func attribute(_ text: String) -> String {
        htmlEscaped(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

extension Notification.Name {
    /// Posted when a recheck makes a different entry the cheapest in its comparison.
    /// `userInfo`: "comparison" (String) and "watch" (UUID) — the new leader.
    static let comparisonLeaderChanged = Notification.Name("RocketComparisonLeaderChanged")
}
