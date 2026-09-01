import Foundation
import WebKit

/// Chrome/Safari-style find-in-page. Owns the search state for one tab and drives the
/// injected JavaScript engine that does the actual matching.
///
/// The engine is injected with `evaluateJavaScript` on demand rather than registered as
/// a `WKUserScript`, and that is deliberate: `ContentBlocker.apply` calls
/// `removeAllUserScripts()`, so a user script would silently disappear the moment any
/// setting was toggled. On-demand injection also means pages nobody searches pay nothing.
///
/// Text matches and OCR matches from `ImageTextScanner` are merged into one list sorted
/// by document position, so ⌘G walks everything in reading order and the counter covers
/// both.
final class FindController {

    struct Results {
        let total: Int
        /// 0-based position of the highlighted match, or -1 when there is none.
        let index: Int
        let images: Int
    }

    private weak var webView: WKWebView?
    private let scanner = ImageTextScanner()

    private(set) var query = ""
    private var isInstalled = false
    private var searchDebounce: DispatchWorkItem?
    /// Bumped whenever the query changes or the page navigates; every asynchronous
    /// step carries the value it started with and drops itself if it no longer matches.
    private var generation = 0
    private var isScanningImages = false

    /// total, index, whether an image scan is still running.
    var onResults: ((Int, Int, Bool) -> Void)?

    init(webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - Lifecycle

    /// The engine lives in the page, so a navigation throws it away along with every
    /// match and every cached OCR result.
    func pageChanged() {
        isInstalled = false
        generation &+= 1
        isScanningImages = false
        scanner.reset()
        searchDebounce?.cancel()
    }

    func teardown() {
        generation &+= 1
        searchDebounce?.cancel()
        scanner.cancel()
        webView = nil
    }

    // MARK: - Searching

    func search(_ text: String, immediately: Bool = false) {
        query = text
        searchDebounce?.cancel()

        guard !text.isEmpty else {
            generation &+= 1
            isScanningImages = false
            scanner.cancel()
            run("window.__rocketFind.clear();")
            onResults?(0, -1, false)
            return
        }

        let work = DispatchWorkItem { [weak self] in self?.performSearch(text) }
        searchDebounce = work
        // Same beat as the address bar's suggestion debounce, so typing stays smooth.
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.12), execute: work)
    }

    private func performSearch(_ text: String) {
        generation &+= 1
        let token = generation
        guard let literal = FindQuery.javaScriptLiteral(text) else { return }
        isScanningImages = ImageTextScanner.isEnabled

        run("window.__rocketFind.search(\(literal));") { [weak self] value in
            guard let self, token == self.generation else { return }
            let results = FindController.results(from: value)
            self.onResults?(results.total, results.index, self.isScanningImages)
            self.scanImages(for: text, token: token)
        }
    }

    /// Re-runs the current search from scratch. Used after a reflow, where every cached
    /// range rectangle is stale.
    func refresh() {
        guard !query.isEmpty else { return }
        performSearch(query)
    }

    func step(_ delta: Int) {
        guard !query.isEmpty else { return }
        let token = generation
        run("window.__rocketFind.step(\(delta));") { [weak self] value in
            guard let self, token == self.generation else { return }
            let results = FindController.results(from: value)
            self.onResults?(results.total, results.index, self.isScanningImages)
        }
    }

    func clear() {
        generation &+= 1
        query = ""
        isScanningImages = false
        scanner.cancel()
        searchDebounce?.cancel()
        run("window.__rocketFind.clear();")
    }

    /// The page scrolled under the user: images that were off-screen may now be
    /// readable. Scrolling caused by `reveal` is filtered out in the page itself, so
    /// walking the matches never restarts the scan that is finding them.
    func viewportScrolled() {
        guard !query.isEmpty, ImageTextScanner.isEnabled else { return }
        scanImages(for: query, token: generation)
    }

    /// Reads whatever the user has selected in the page, so ⌘E and ⌘F can prefill.
    func currentSelection(_ completion: @escaping (String) -> Void) {
        guard let webView else { completion(""); return }
        webView.evaluateJavaScript("String(window.getSelection())") { value, _ in
            let text = (value as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A whole paragraph dragged by accident is not a search term.
            completion(text.count <= 120 && !text.contains("\n") ? text : "")
        }
    }

    // MARK: - Image text

    private func scanImages(for text: String, token: Int) {
        guard ImageTextScanner.isEnabled, let webView else {
            isScanningImages = false
            return
        }
        isScanningImages = true
        scanner.scan(webView: webView, query: text) { [weak self] outcome in
            guard let self else { return }
            guard case .matches(let rects) = outcome else {
                // A newer scan took over and owns the label from here.
                return
            }
            self.isScanningImages = false
            guard token == self.generation else { return }
            guard let json = FindQuery.jsonArray(rects) else { return }
            self.run("window.__rocketFind.setImageMatches(\(json));") { value in
                guard token == self.generation else { return }
                let results = FindController.results(from: value)
                self.onResults?(results.total, results.index, false)
            }
        }
    }

    // MARK: - Bridge

    private func run(_ javaScript: String, then handler: ((Any?) -> Void)? = nil) {
        guard let webView else { return }
        let evaluate = { [weak webView] in
            webView?.evaluateJavaScript(javaScript) { value, _ in handler?(value) }
        }
        if isInstalled {
            evaluate()
            return
        }
        webView.evaluateJavaScript(FindInPageScript.source) { [weak self] _, error in
            if error == nil { self?.isInstalled = true }
            evaluate()
        }
    }

    static func results(from value: Any?) -> Results {
        guard let dictionary = value as? [String: Any] else { return Results(total: 0, index: -1, images: 0) }
        return Results(total: dictionary["total"] as? Int ?? 0,
                       index: dictionary["index"] as? Int ?? -1,
                       images: dictionary["images"] as? Int ?? 0)
    }
}

// MARK: - Query encoding

enum FindQuery {

    /// JSON is the only safe way to put user text into a script. A quote, a backslash or
    /// a line separator in the search field must never be able to close the literal and
    /// start executing.
    static func javaScriptLiteral(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2 else { return nil }
        return String(json.dropFirst().dropLast())
    }

    static func jsonArray(_ rects: [CGRect]) -> String? {
        let payload = rects.map {
            ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Injected engine

/// The matching engine, injected once per page load.
///
/// Highlighting goes through the CSS Custom Highlight API rather than wrapping hits in
/// `<mark>` elements: no DOM mutation means nothing for a framework to reconcile away,
/// no reflow, and an instant clear. Pages served before that API existed (macOS 14.0 and
/// 14.1) fall back to selecting the current match, which highlights natively and also
/// leaves the document untouched.
enum FindInPageScript {

    static let source = engine + "\ntrue;"

    private static let engine = #"""
    (function () {
        'use strict';
        if (window.__rocketFind) { return; }

        var MAX_MATCHES = 2000;
        var MIN_IMAGE_SIDE = 48;
        var MAX_IMAGE_REGIONS = 8;
        // Scrolling the page to a match is our own doing, and must not be reported
        // back as a viewport change — that would cancel the scan already running.
        var selfScrollUntil = 0;
        var OVERLAY_ID = '__rocketFindOverlay';
        var ALL = 'rocket-find';
        var CURRENT = 'rocket-find-current';

        var matches = [];
        var textMatches = [];
        var imageMatches = [];
        var current = -1;
        var query = '';
        var ocrSeq = 0;
        var usedSelection = false;

        var supportsHighlights = typeof CSS !== 'undefined' && !!CSS.highlights &&
                                 typeof Highlight !== 'undefined' && typeof Range !== 'undefined';

        // --- styling -------------------------------------------------------

        var STYLE = '::highlight(' + ALL + '){background-color:#ffe066;color:#000}' +
                    '::highlight(' + CURRENT + '){background-color:#ff8c1a;color:#000}';

        function installStyle() {
            // A constructable sheet first: a strict Content-Security-Policy can refuse
            // an injected <style> element, but never an adopted stylesheet.
            try {
                var sheet = new CSSStyleSheet();
                sheet.replaceSync(STYLE);
                document.adoptedStyleSheets = document.adoptedStyleSheets.concat([sheet]);
                return;
            } catch (e) {}
            try {
                var element = document.createElement('style');
                element.textContent = STYLE;
                (document.head || document.documentElement).appendChild(element);
            } catch (e) {}
        }

        if (supportsHighlights) { installStyle(); }

        // --- text collection -----------------------------------------------

        var INLINE = {
            'inline': 1, 'inline-block': 1, 'inline-flex': 1, 'inline-grid': 1,
            'inline-table': 1, 'contents': 1, 'ruby': 1, 'ruby-text': 1, 'ruby-base': 1
        };

        function isSpace(ch) {
            return ch === ' ' || ch === '\n' || ch === '\t' || ch === '\r' ||
                   ch === '\f' || ch === '\u00A0' || ch === '\u200B';
        }

        /// Walks the rendered text into one buffer, collapsing whitespace the way the
        /// page renders it so "foo bar" still matches markup broken across lines and
        /// inline elements. Every buffer character keeps a back-pointer to the text node
        /// and offset it came from, which is what lets a match become a DOM Range.
        function collect() {
            var nodes = [];
            var nodeOf = [];
            var offsetOf = [];
            var buffer = '';
            var displayCache = new Map();
            var overlay = document.getElementById(OVERLAY_ID);

            if (!document.body) {
                return { buffer: '', rangeFor: function () { return null; } };
            }

            function displayOf(element) {
                var display = displayCache.get(element);
                if (display === undefined) {
                    display = getComputedStyle(element).display;
                    displayCache.set(element, display);
                }
                return display;
            }

            function blockAncestor(element) {
                while (element && element !== document.body) {
                    if (!INLINE[displayOf(element)]) { return element; }
                    element = element.parentElement;
                }
                return document.body;
            }

            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
                acceptNode: function (node) {
                    if (!node.nodeValue) { return NodeFilter.FILTER_REJECT; }
                    var parent = node.parentElement;
                    if (!parent) { return NodeFilter.FILTER_REJECT; }
                    var tag = parent.tagName;
                    if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' ||
                        tag === 'TEXTAREA' || tag === 'TITLE') {
                        return NodeFilter.FILTER_REJECT;
                    }
                    if (overlay && overlay.contains(parent)) { return NodeFilter.FILTER_REJECT; }
                    // One native call covers display:none, visibility:hidden and
                    // content-visibility. Testing offsetParent instead would miss
                    // visibility:hidden, which still occupies layout.
                    if (parent.checkVisibility) {
                        if (!parent.checkVisibility({ visibilityProperty: true,
                                                      contentVisibilityAuto: true })) {
                            return NodeFilter.FILTER_REJECT;
                        }
                    } else {
                        var style = getComputedStyle(parent);
                        if (style.display === 'none' || style.visibility === 'hidden') {
                            return NodeFilter.FILTER_REJECT;
                        }
                        // offsetParent is also null for position:fixed, which is visible.
                        if (parent.offsetParent === null && style.position !== 'fixed' &&
                            parent !== document.body) {
                            return NodeFilter.FILTER_REJECT;
                        }
                    }
                    return NodeFilter.FILTER_ACCEPT;
                }
            });

            var previousBlock = null;
            var pendingSpace = false;
            var pendingBreak = false;
            var node;

            while ((node = walker.nextNode())) {
                var block = blockAncestor(node.parentElement);
                if (previousBlock !== null && block !== previousBlock) { pendingBreak = true; }
                previousBlock = block;

                var value = node.nodeValue;
                var slot = nodes.length;
                nodes.push(node);

                for (var i = 0; i < value.length; i++) {
                    var ch = value[i];
                    if (isSpace(ch)) { pendingSpace = true; continue; }
                    if ((pendingBreak || pendingSpace) && buffer.length > 0) {
                        // A block boundary becomes a newline, never a space, so a query
                        // containing a space cannot match across two paragraphs.
                        buffer += pendingBreak ? '\n' : ' ';
                        nodeOf.push(slot);
                        offsetOf.push(i);
                    }
                    pendingSpace = false;
                    pendingBreak = false;
                    buffer += ch;
                    nodeOf.push(slot);
                    offsetOf.push(i);
                }
            }

            return {
                buffer: buffer,
                rangeFor: function (start, end) {
                    if (start < 0 || end > nodeOf.length || end <= start) { return null; }
                    var last = end - 1;
                    try {
                        var range = document.createRange();
                        range.setStart(nodes[nodeOf[start]], offsetOf[start]);
                        range.setEnd(nodes[nodeOf[last]], offsetOf[last] + 1);
                        return range;
                    } catch (e) {
                        return null;
                    }
                }
            };
        }

        /// Lowercases without ever changing the string's length, so buffer offsets stay
        /// valid. A few characters (İ, ﬁ) grow when lowercased; those keep their original
        /// form rather than shifting every index after them.
        function fold(text) {
            var out = '';
            for (var i = 0; i < text.length; i++) {
                var ch = text[i];
                var lower = ch.toLowerCase();
                out += (lower.length === 1) ? lower : ch;
            }
            return out;
        }

        // --- highlighting ---------------------------------------------------

        function applyHighlights() {
            if (!supportsHighlights) {
                if (current >= 0 && matches[current] && matches[current].kind === 'text') {
                    try {
                        var selection = window.getSelection();
                        selection.removeAllRanges();
                        selection.addRange(matches[current].range);
                        usedSelection = true;
                    } catch (e) {}
                }
                return;
            }
            var rest = [];
            var focused = [];
            for (var i = 0; i < matches.length; i++) {
                if (matches[i].kind !== 'text') { continue; }
                if (i === current) { focused.push(matches[i].range); } else { rest.push(matches[i].range); }
            }
            try {
                if (rest.length) {
                    // Highlight is Set-like, so ranges go in one at a time rather
                    // than through a variadic constructor call.
                    var highlight = new Highlight();
                    for (var j = 0; j < rest.length; j++) { highlight.add(rest[j]); }
                    CSS.highlights.set(ALL, highlight);
                } else {
                    CSS.highlights.delete(ALL);
                }
            } catch (e) {}
            try {
                if (focused.length) {
                    CSS.highlights.set(CURRENT, new Highlight(focused[0]));
                } else {
                    CSS.highlights.delete(CURRENT);
                }
            } catch (e) {}
        }

        function overlayHost(create) {
            var host = document.getElementById(OVERLAY_ID);
            if (host || !create || !document.body) { return host; }
            host = document.createElement('div');
            host.id = OVERLAY_ID;
            // Every value is written through CSSOM rather than a style attribute: a
            // Content-Security-Policy blocks parsed inline styles, not scripted writes.
            var style = host.style;
            style.position = 'absolute';
            style.top = '0';
            style.left = '0';
            style.width = '0';
            style.height = '0';
            style.margin = '0';
            style.padding = '0';
            style.border = '0';
            style.zIndex = '2147483646';
            style.pointerEvents = 'none';
            document.body.appendChild(host);
            return host;
        }

        function drawOverlays() {
            var host = overlayHost(imageMatches.length > 0);
            if (!host) { return; }
            while (host.firstChild) { host.removeChild(host.firstChild); }
            if (!imageMatches.length) { return; }

            // The host sits inside <body>, which may itself be offset or positioned;
            // measuring it converts document coordinates into host-local ones.
            var origin = host.getBoundingClientRect();
            var originX = origin.left + window.scrollX;
            var originY = origin.top + window.scrollY;

            for (var i = 0; i < matches.length; i++) {
                var match = matches[i];
                if (match.kind !== 'image') { continue; }
                var box = document.createElement('div');
                var style = box.style;
                style.position = 'absolute';
                style.left = (match.left - originX) + 'px';
                style.top = (match.top - originY) + 'px';
                style.width = match.width + 'px';
                style.height = match.height + 'px';
                style.borderRadius = '2px';
                style.pointerEvents = 'none';
                style.boxSizing = 'border-box';
                if (i === current) {
                    style.backgroundColor = 'rgba(255,140,26,0.45)';
                    style.border = '2px solid #ff8c1a';
                } else {
                    style.backgroundColor = 'rgba(255,224,102,0.40)';
                    style.border = '1px solid rgba(190,150,0,0.75)';
                }
                host.appendChild(box);
            }
        }

        /// Merges text and image hits into one list ordered by document position, so a
        /// single counter and a single ⌘G cycle covers both.
        function rebuild() {
            var previous = (current >= 0 && current < matches.length) ? matches[current] : null;
            matches = textMatches.concat(imageMatches);
            matches.sort(function (a, b) {
                if (Math.abs(a.top - b.top) > 4) { return a.top - b.top; }
                return a.left - b.left;
            });
            current = previous ? matches.indexOf(previous) : -1;
            applyHighlights();
            drawOverlays();
        }

        function counts() {
            return { total: matches.length, index: current, images: imageMatches.length };
        }

        function reveal(match) {
            if (!match) { return; }
            selfScrollUntil = Date.now() + 500;
            if (match.kind === 'text') {
                // Scrolling the parent first walks every nested scroll container; the
                // window nudge afterwards centres the hit within whatever came into view.
                var element = match.range.startContainer.parentElement;
                if (element && element.scrollIntoView) {
                    try {
                        element.scrollIntoView({ block: 'center', inline: 'nearest' });
                    } catch (e) {
                        element.scrollIntoView();
                    }
                }
                var rect = match.range.getBoundingClientRect();
                if (rect.top < 60 || rect.bottom > window.innerHeight - 40) {
                    window.scrollBy(0, rect.top - window.innerHeight / 2);
                }
            } else {
                window.scrollTo(Math.max(0, match.left - window.innerWidth / 2),
                                Math.max(0, match.top - window.innerHeight / 2));
            }
        }

        // --- public API -----------------------------------------------------

        function clear() {
            query = '';
            matches = [];
            textMatches = [];
            imageMatches = [];
            current = -1;
            if (supportsHighlights) {
                try { CSS.highlights.delete(ALL); } catch (e) {}
                try { CSS.highlights.delete(CURRENT); } catch (e) {}
            } else if (usedSelection) {
                try { window.getSelection().removeAllRanges(); } catch (e) {}
                usedSelection = false;
            }
            var host = overlayHost(false);
            if (host && host.parentNode) { host.parentNode.removeChild(host); }
            return counts();
        }

        function search(text) {
            clear();
            query = text || '';
            if (!query) { return counts(); }

            var data = collect();
            var haystack = fold(data.buffer);
            var needle = fold(query);
            if (!needle) { return counts(); }

            var from = 0;
            var hit;
            while (textMatches.length < MAX_MATCHES &&
                   (hit = haystack.indexOf(needle, from)) !== -1) {
                var range = data.rangeFor(hit, hit + needle.length);
                if (range) {
                    var rect = range.getBoundingClientRect();
                    if (rect.width > 0 || rect.height > 0) {
                        textMatches.push({
                            kind: 'text',
                            range: range,
                            top: rect.top + window.scrollY,
                            left: rect.left + window.scrollX,
                            width: rect.width,
                            height: rect.height
                        });
                    }
                }
                from = hit + Math.max(1, needle.length);
            }

            rebuild();
            if (matches.length) {
                current = 0;
                applyHighlights();
                drawOverlays();
                reveal(matches[0]);
            }
            return counts();
        }

        function step(delta) {
            if (!matches.length) { current = -1; return counts(); }
            if (current < 0) {
                current = delta >= 0 ? 0 : matches.length - 1;
            } else {
                current = (current + delta + matches.length) % matches.length;
            }
            applyHighlights();
            drawOverlays();
            reveal(matches[current]);
            return counts();
        }

        /// Viewport rectangles of everything that renders an image, for the OCR pass.
        function imageRegions() {
            if (!document.body) { return { regions: [] }; }
            var viewportWidth = document.documentElement.clientWidth;
            var viewportHeight = document.documentElement.clientHeight;
            var overlay = document.getElementById(OVERLAY_ID);
            var candidates = new Set();

            var media = document.querySelectorAll('img, canvas, svg, video, object');
            for (var i = 0; i < media.length; i++) { candidates.add(media[i]); }

            // Background images need getComputedStyle, which is the expensive part, so
            // the cheap rectangle test runs first and almost always rejects.
            var all = document.body.querySelectorAll('*');
            var limit = Math.min(all.length, 4000);
            for (var j = 0; j < limit; j++) {
                var element = all[j];
                if (candidates.has(element)) { continue; }
                var box = element.getBoundingClientRect();
                if (box.width < 96 || box.height < 96) { continue; }
                if (box.bottom <= 0 || box.top >= viewportHeight ||
                    box.right <= 0 || box.left >= viewportWidth) { continue; }
                var background = getComputedStyle(element).backgroundImage;
                if (background && background !== 'none' && background.indexOf('url(') !== -1) {
                    candidates.add(element);
                }
            }

            var regions = [];
            candidates.forEach(function (element) {
                if (overlay && overlay.contains(element)) { return; }
                var box = element.getBoundingClientRect();
                if (box.width < MIN_IMAGE_SIDE || box.height < MIN_IMAGE_SIDE) { return; }
                if (box.bottom <= 0 || box.top >= viewportHeight ||
                    box.right <= 0 || box.left >= viewportWidth) { return; }
                var whole = box.top >= 0 && box.left >= 0 &&
                            box.bottom <= viewportHeight && box.right <= viewportWidth;
                var oversized = box.height > viewportHeight || box.width > viewportWidth;
                // Anything merely half-scrolled is left for the pass after it has come
                // fully into view: its crop would change with every pixel of scrolling,
                // so it could never be cached, and half a word is not worth reading.
                if (!whole && !oversized) { return; }

                var x = Math.max(0, box.left);
                var y = Math.max(0, box.top);
                var width = Math.min(viewportWidth, box.right) - x;
                var height = Math.min(viewportHeight, box.bottom) - y;
                if (width < MIN_IMAGE_SIDE || height < MIN_IMAGE_SIDE) { return; }
                if (!element.__rocketOcrId) { element.__rocketOcrId = 'r' + (++ocrSeq); }
                regions.push({
                    x: x, y: y, width: width, height: height,
                    // A wholly visible image is keyed by identity and size alone, so it
                    // is recognised once and then reused however the page scrolls. Only
                    // images bigger than the window carry their crop in the key.
                    key: element.__rocketOcrId + ':' +
                         Math.round(box.width) + 'x' + Math.round(box.height) +
                         (whole ? '' : ':' + Math.round(x - box.left) + ',' +
                                       Math.round(y - box.top) + ':' +
                                       Math.round(width) + 'x' + Math.round(height))
                });
            });

            regions.sort(function (a, b) { return (b.width * b.height) - (a.width * a.height); });
            return {
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight,
                scrollX: window.scrollX,
                scrollY: window.scrollY,
                regions: regions.slice(0, MAX_IMAGE_REGIONS)
            };
        }

        /// Document-space rectangles for text recognised inside images.
        function setImageMatches(list) {
            imageMatches = [];
            for (var i = 0; i < (list || []).length; i++) {
                var item = list[i];
                imageMatches.push({
                    kind: 'image',
                    left: item.x, top: item.y,
                    width: item.width, height: item.height
                });
            }
            rebuild();
            if (current < 0 && matches.length) { current = 0; applyHighlights(); drawOverlays(); }
            return counts();
        }

        // --- layout notifications -------------------------------------------

        function notify(action) {
            try {
                window.webkit.messageHandlers.rocket.postMessage({ action: action });
            } catch (e) {}
        }

        var scrollTimer = null;
        window.addEventListener('scroll', function () {
            if (!query || Date.now() < selfScrollUntil) { return; }
            if (scrollTimer) { clearTimeout(scrollTimer); }
            scrollTimer = setTimeout(function () {
                if (Date.now() < selfScrollUntil) { return; }
                notify('findScrolled');
            }, 250);
        }, { passive: true, capture: true });

        var resizeTimer = null;
        window.addEventListener('resize', function () {
            if (!query) { return; }
            if (resizeTimer) { clearTimeout(resizeTimer); }
            // A reflow invalidates every cached rectangle, so this asks for a full
            // re-search rather than only a new image pass.
            resizeTimer = setTimeout(function () { notify('findReflowed'); }, 300);
        }, { passive: true });

        window.__rocketFind = {
            search: search,
            step: step,
            clear: clear,
            imageRegions: imageRegions,
            setImageMatches: setImageMatches
        };
    })();
    """#
}
