import Cocoa
import WebKit

/// Rechecks watched values in a web view that never appears on screen.
///
/// Loading the page is the only honest way to read a price: most of them are written in
/// by script, so fetching the HTML and hunting through it would report yesterday's markup
/// or nothing at all. Rocket is a browser, so it uses one. The check runs against the
/// normal website data store, which is what lets a page that needs your session and your
/// region show you *your* price.
///
/// Off-screen web views are throttled hard by WebKit — measured at roughly 1 Hz for a
/// timer that asks for 20 — so the value is polled for a few seconds rather than read
/// once after a fixed delay. Checks run strictly one at a time: this is a background
/// errand, not a crawl.
final class PageWatchChecker: NSObject, WKNavigationDelegate {

    static let shared = PageWatchChecker()

    private static let pollInterval: TimeInterval = 1
    private static let pollLimit = 12
    private static let loadTimeout: TimeInterval = 45
    /// A price written in by script shows a placeholder first — "loading…", a skeleton,
    /// the old value — so the first reading after `didFinish` is routinely a lie, and
    /// reading twice in quick succession just gets the same lie twice. The value has to
    /// hold still across two reads *and* outlast this floor before it is believed.
    ///
    /// ponytail: a fixed floor, not a real quiescence signal. A page that fills its
    /// price in later than this records the placeholder; a MutationObserver on the
    /// watched element would be the upgrade if that ever shows up in practice.
    private static let settleFloor: TimeInterval = 5

    private var pending: [UUID] = []
    private var webView: WKWebView?
    private var selector: String?
    private var completion: ((String?) -> Void)?
    private var timeout: DispatchWorkItem?

    // MARK: - Scheduling

    func checkDue(at date: Date = Date()) {
        enqueue(PageWatchStore.shared.due(at: date).map(\.id))
    }

    func check(ids: [UUID]) {
        enqueue(ids)
    }

    private func enqueue(_ ids: [UUID]) {
        for id in ids where !pending.contains(id) { pending.append(id) }
        runNext()
    }

    private func runNext() {
        guard webView == nil, !pending.isEmpty else { return }
        let id = pending.removeFirst()
        guard let watch = PageWatchStore.shared.watch(id: id), let url = URL(string: watch.url) else {
            runNext()
            return
        }
        load(watch, url: url) { [weak self] value in
            self?.record(watch: watch, value: value)
            self?.runNext()
        }
    }

    // MARK: - One check

    private func load(_ watch: PageWatch, url: URL, completion: @escaping (String?) -> Void) {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900),
                                configuration: BrowserWindowController.makeConfiguration())
        // `innerText` is layout-dependent — it reports what is actually shown, which is
        // the point — so this view has a real size even though nothing ever draws it.
        ContentBlocker.shared.apply(to: webView)
        webView.navigationDelegate = self
        self.webView = webView
        self.selector = watch.selector
        self.completion = completion
        let timeout = DispatchWorkItem { [weak self] in self?.deliver(nil) }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loadTimeout, execute: timeout)
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        poll(attempt: 0, previous: nil, since: Date())
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        deliver(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        deliver(nil)
    }

    private func poll(attempt: Int, previous: String?, since: Date) {
        guard let webView, let selector else { return }
        webView.callAsyncJavaScript(Self.readScript, arguments: ["selector": selector],
                                    in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            let text = ((try? result.get()) as? String).flatMap { $0.isEmpty ? nil : $0 }
            let settled = text != nil && text == previous
                && Date().timeIntervalSince(since) >= Self.settleFloor
            guard !settled, attempt + 1 < Self.pollLimit else {
                // Out of patience: report the last thing the page actually said, which
                // may be nothing at all.
                self.deliver(text)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval) {
                self.poll(attempt: attempt + 1, previous: text, since: since)
            }
        }
    }

    /// Ends the check, whichever of the timeout, a failure or a reading got here first.
    private func deliver(_ value: String?) {
        timeout?.cancel()
        timeout = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        selector = nil
        let completion = self.completion
        self.completion = nil
        completion?(value)
    }

    private func record(watch: PageWatch, value: String?) {
        let store = PageWatchStore.shared
        guard let value else {
            store.update(id: watch.id) { current in
                current.checkedAt = Date()
                if current.missingSince == nil { current.missingSince = Date() }
            }
            return
        }
        let change = WatchValue.compare(old: watch.value, new: value)
        store.update(id: watch.id) { current in
            current.checkedAt = Date()
            current.missingSince = nil
            guard change != .unchanged else { return }
            current.previousValue = current.value
            current.value = value
            current.changedAt = Date()
            current.unread = true
        }
        guard change != .unchanged else { return }
        // A Dock badge and a bounce rather than a system notification:
        // `UNUserNotificationCenter` wants a registered bundle and raises rather than
        // failing when it does not have one, which is a poor trade for a badge. The
        // badge itself is set from the store's notification, in AppDelegate.
        NSApp.requestUserAttention(.informationalRequest)
    }

    // MARK: - Page scripts
    //
    // Both run in the client's isolated world, and the selector rides as an argument
    // rather than spliced into source — the same rule autofill follows.

    static let readScript = """
        const element = document.querySelector(selector);
        return element ? element.innerText.trim().replace(/\\s+/g, ' ') : null;
        """

    /// Turns the current selection into a watchable element: the CSS path to it, the
    /// element's whole text, and whether that path really does select that element —
    /// which the caller refuses the watch without.
    static let captureScript = """
        const selection = window.getSelection();
        if (!selection || selection.rangeCount === 0 || selection.isCollapsed) { return null; }
        let node = selection.getRangeAt(0).commonAncestorContainer;
        if (node.nodeType === Node.TEXT_NODE) { node = node.parentElement; }
        if (!node || node.nodeType !== Node.ELEMENT_NODE) { return null; }

        const escape = (value) => (window.CSS && CSS.escape) ? CSS.escape(value) : value;
        const path = [];
        for (let el = node; el && el !== document.documentElement; el = el.parentElement) {
            // An id that is unique on the page outlives every structural change above it.
            if (el.id && document.querySelectorAll('#' + escape(el.id)).length === 1) {
                path.unshift('#' + escape(el.id));
                break;
            }
            const tag = el.tagName.toLowerCase();
            const parent = el.parentElement;
            const twins = parent ? Array.from(parent.children).filter(c => c.tagName === el.tagName) : [el];
            path.unshift(twins.length > 1 ? tag + ':nth-of-type(' + (twins.indexOf(el) + 1) + ')' : tag);
        }
        const selector = path.join(' > ');
        let ok = false;
        try { ok = document.querySelector(selector) === node; } catch (e) { ok = false; }
        return {
            selector: selector,
            value: (node.innerText || '').trim().replace(/\\s+/g, ' '),
            title: document.title,
            ok: ok
        };
        """
}
