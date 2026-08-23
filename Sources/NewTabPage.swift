import Foundation
import WebKit

/// The local start page shown in new tabs and windows, with a user-chosen wallpaper.
/// Lives in ~/Library/Application Support/Rocket/ as a generated HTML file; the
/// wallpaper is a copied image file whose name changes on every change (cache busting).
enum NewTabPage {

    static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Rocket", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static var pageFileURL: URL {
        directory.appendingPathComponent("newtab.html")
    }

    static var wallpaperURL: URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.lastPathComponent.hasPrefix("wallpaper-") }
    }

    static func isNewTabURL(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        return url.standardizedFileURL.path == pageFileURL.standardizedFileURL.path
    }

    static func setWallpaper(from source: URL) throws {
        removeWallpaperFiles()
        let ext = source.pathExtension.isEmpty ? "img" : source.pathExtension
        let name = "wallpaper-\(Int(Date().timeIntervalSince1970)).\(ext)"
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(name))
    }

    static func clearWallpaper() {
        removeWallpaperFiles()
    }

    private static func removeWallpaperFiles() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in contents where file.lastPathComponent.hasPrefix("wallpaper-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func open(in webView: WKWebView) {
        try? generateHTML().data(using: .utf8)?.write(to: pageFileURL, options: .atomic)
        webView.loadFileURL(pageFileURL, allowingReadAccessTo: directory)
    }

    private static func generateHTML() -> String {
        let background: String
        if let wallpaper = wallpaperURL {
            background = "background: #111 url('\(wallpaper.lastPathComponent)') center / cover no-repeat fixed;"
        } else {
            background = "background: linear-gradient(160deg, #1c1240, #3b1d63 55%, #0d2a4a);"
        }
        let suggestions = SuggestionEngine.shared.suggestions()
        var suggestionsHTML = ""
        if !suggestions.isEmpty {
            let chips = suggestions.map { suggestion in
                "<a class=\"chip\" href=\"\(htmlEscaped(suggestion.url))\">\(htmlEscaped(suggestion.host))</a>"
            }.joined()
            suggestionsHTML = "<div class=\"chips\">\(chips)</div>"
        }
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>New Tab</title>
        <style>
            html, body { height: 100%; margin: 0; }
            body {
                \(background)
                display: flex; align-items: center; justify-content: center;
                font-family: -apple-system, sans-serif;
                -webkit-user-select: none; cursor: default;
            }
            .clock { text-align: center; color: #fff; text-shadow: 0 2px 28px rgba(0,0,0,.6); }
            .time { font-size: 96px; font-weight: 700; letter-spacing: -2px; font-variant-numeric: tabular-nums; }
            .date { font-size: 20px; font-weight: 500; opacity: .85; margin-top: 2px; }
            .chips { margin-top: 30px; display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; }
            .chip { padding: 8px 16px; border-radius: 999px; background: rgba(255,255,255,.16);
                    color: #fff; text-decoration: none; font-size: 14px; font-weight: 500;
                    cursor: pointer; backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px);
                    text-shadow: none; transition: background .15s; }
            .chip:hover { background: rgba(255,255,255,.30); }
        </style>
        </head>
        <body>
        <div class="clock"><div class="time" id="time"></div><div class="date" id="date"></div>\(suggestionsHTML)</div>
        <script>
            function tick() {
                const now = new Date();
                document.getElementById('time').textContent =
                    now.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
                document.getElementById('date').textContent =
                    now.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' });
            }
            tick();
            setInterval(tick, 10000);
        </script>
        </body>
        </html>
        """
    }
}
