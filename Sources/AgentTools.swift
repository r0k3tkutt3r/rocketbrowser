import Cocoa
import WebKit

/// One MCP tool: the schema `tools/list` advertises and the handler `tools/call` runs.
struct AgentTool {
    let name: String
    let description: String
    /// JSON Schema for the arguments; must be serialisable by JSONSerialization.
    let inputSchema: [String: Any]
    /// Always called on the main thread. Must call `done` exactly once (any thread is fine).
    let run: (_ arguments: [String: Any], _ context: AgentContext,
              _ done: @escaping (Result<[AgentContent], AgentError>) -> Void) -> Void
}

enum AgentContent {
    case text(String)
    /// PNG bytes, base64-encoded.
    case image(pngBase64: String)
}

struct AgentError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// What the tools may reach. Incognito tabs are never in here — `AgentServer` filters them.
struct AgentContext {
    let tabs: () -> [BrowserWindowController]
    let front: () -> BrowserWindowController?
    /// Opens a new tab in the front normal window (or a new window) and returns it, already loading.
    let open: (URL) -> BrowserWindowController
}

// MARK: - Shared helpers
//
// Every tool but `tabs`/`open` takes the same optional `tab` argument and reports the same
// tab state back, so that lookup, the describe format, and the post-navigation settle all
// live here once instead of ten times.

private let allowedURLSchemes: Set<String> = ["http", "https", "file", "about"]

/// Rejects anything that is not a URL this browser can sensibly open — a bare word typed
/// into `url` would otherwise become a search-engine query nobody asked for.
private func validatedURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
          allowedURLSchemes.contains(scheme) else { return nil }
    return url
}

/// JSON numbers arrive through `JSONSerialization` as `NSNumber`; this also accepts a bare
/// `Int` and a numeric string so a slightly-off client doesn't just fail silently.
private func argInt(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
}

private func resolveTab(_ args: [String: Any], _ context: AgentContext) throws -> BrowserWindowController {
    if let raw = args["tab"] {
        guard let id = argInt(raw) else { throw AgentError("tab must be a number") }
        guard let match = context.tabs().first(where: { $0.agentTabID == id }) else {
            throw AgentError("no such tab #\(id) — call tabs")
        }
        return match
    }
    guard let front = context.front() else { throw AgentError("no tabs open — call open") }
    return front
}

/// Resolves the `tab` argument and turns a thrown `AgentError` into `done(.failure(...))`,
/// which every tool needs, so it lives here once instead of a repeated do/catch.
private func withTab(_ args: [String: Any], _ context: AgentContext,
                     _ done: (Result<[AgentContent], AgentError>) -> Void,
                     _ body: (BrowserWindowController) -> Void) {
    do {
        body(try resolveTab(args, context))
    } catch let error as AgentError {
        done(.failure(error))
    } catch {
        done(.failure(AgentError(error.localizedDescription)))
    }
}

private func describe(_ c: BrowserWindowController) -> String {
    let url = c.webView.url?.absoluteString ?? "about:blank"
    return "#\(c.agentTabID) \(url) — \(c.webView.title ?? "")"
}

/// Polls on main every 100 ms until `isLoading` has read false twice in a row (one clean
/// read is routinely a redirect mid-flight), or `timeout` passes — whichever comes first.
private func waitForLoad(_ c: BrowserWindowController, timeout: TimeInterval = 20,
                         then: @escaping (BrowserWindowController) -> Void) {
    let deadline = Date().addingTimeInterval(timeout)
    var stableReads = 0
    func poll() {
        if c.webView.isLoading {
            stableReads = 0
        } else {
            stableReads += 1
            if stableReads >= 2 { then(c); return }
        }
        guard Date() < deadline else { then(c); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
    }
    // Not straight away: give the navigation just asked for a tick to register.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
}

/// The tail end of `click`/`type`: a synthetic click or keystroke may kick off a
/// navigation, so this gives the page a moment to start one, rides it out if it did, and
/// reports whether the URL actually moved.
private func finishAction(_ controller: BrowserWindowController, urlBefore: URL?,
                          done: @escaping (Result<[AgentContent], AgentError>) -> Void) {
    func respond() {
        var text = describe(controller)
        if controller.webView.url != urlBefore { text += " (navigated)" }
        done(.success([.text(text)]))
    }
    if controller.webView.isLoading {
        waitForLoad(controller) { _ in respond() }
    } else {
        respond()
    }
}

/// `evaluate`'s result value: JS `undefined`/`null` bridge to `NSNull`, an array or
/// dictionary is rendered as JSON, and everything else (`String`, `NSNumber`, `Bool`)
/// already prints sensibly with `String(describing:)`.
private func describeJSValue(_ value: Any) -> String {
    if value is NSNull { return "undefined" }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
        return json
    }
    return String(describing: value)
}

/// The MCP tool table an AI agent drives Rocket through, plus the page scripts `snapshot`,
/// `click` and `type` run.
enum AgentTools {

    /// `click`/`type`/`snapshot` run in their own content world rather than `.page`: it has
    /// its own pristine copies of the DOM prototypes, so a page that has monkey-patched
    /// `HTMLInputElement.prototype.value` (or `Element.prototype.click`) still gets a real
    /// value change and a real click — same reasoning as `PasswordAutofill`'s isolated
    /// world. Its `window` persists across calls for the document's lifetime, which is what
    /// lets `window.__rocketRefs` (built by `snapshot`) still be there when `click`/`type`
    /// run moments later.
    static let agentWorld = WKContentWorld.world(name: "RocketAgent")

    static let all: [AgentTool] = [

        AgentTool(
            name: "tabs",
            description: "List open tabs, one line each: id, URL, title. The front tab is prefixed with \"* \".",
            inputSchema: ["type": "object", "properties": [String: Any]()],
            run: { _, context, done in
                let open = context.tabs()
                guard !open.isEmpty else { done(.success([.text("(no tabs open)")])); return }
                let front = context.front()
                let lines = open.map { ($0 === front ? "* " : "  ") + describe($0) }
                done(.success([.text(lines.joined(separator: "\n"))]))
            }
        ),

        AgentTool(
            name: "open",
            description: "Open a URL in a new tab and wait for it to finish loading.",
            inputSchema: [
                "type": "object",
                "properties": ["url": ["type": "string", "description": "http, https, file or about URL to open."]],
                "required": ["url"]
            ],
            run: { args, context, done in
                guard let raw = args["url"] as? String, let url = validatedURL(raw) else {
                    done(.failure(AgentError("url must be a string with an http, https, file or about scheme")))
                    return
                }
                waitForLoad(context.open(url)) { done(.success([.text(describe($0))])) }
            }
        ),

        AgentTool(
            name: "navigate",
            description: "Load a URL in an existing tab (or the front tab) and wait for it to finish loading.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "http, https, file or about URL to load."],
                    "tab": ["type": "integer", "description": "Tab id from `tabs`. Defaults to the front tab."]
                ],
                "required": ["url"]
            ],
            run: { args, context, done in
                guard let raw = args["url"] as? String, let url = validatedURL(raw) else {
                    done(.failure(AgentError("url must be a string with an http, https, file or about scheme")))
                    return
                }
                withTab(args, context, done) { controller in
                    controller.load(url)
                    waitForLoad(controller) { done(.success([.text(describe($0))])) }
                }
            }
        ),

        AgentTool(
            name: "read",
            description: "Return the page's visible text (document.body.innerText).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "tab": ["type": "integer", "description": "Tab id from `tabs`. Defaults to the front tab."],
                    "max_chars": ["type": "integer",
                                 "description": "Truncate the returned text past this many characters. Default 40000."]
                ]
            ],
            run: { args, context, done in
                withTab(args, context, done) { controller in
                    let maxChars = argInt(args["max_chars"]) ?? 40000
                    controller.webView.callAsyncJavaScript(
                        "return document.body ? document.body.innerText : '';",
                        arguments: [:], in: nil, in: .page) { result in
                        switch result {
                        case .failure(let error):
                            done(.failure(AgentError(error.localizedDescription)))
                        case .success(let value):
                            let text = (value as? String) ?? ""
                            let header = describe(controller) + "\n\n"
                            guard text.count > maxChars else { done(.success([.text(header + text)])); return }
                            let cut = String(text.prefix(maxChars))
                            let more = text.count - maxChars
                            done(.success([.text(header + cut
                                + "\n\n[truncated: \(more) more characters — pass max_chars or use evaluate]")]))
                        }
                    }
                }
            }
        ),

        AgentTool(
            name: "snapshot",
            description: """
                List clickable/typeable elements as `[ref] role "label"` lines for click/type \
                to act on. Refs reset on every snapshot and whenever the page navigates — snapshot \
                again after the page changes. Elements inside iframes are not listed. Pass query to \
                narrow a large page to matching lines.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "tab": ["type": "integer", "description": "Tab id from `tabs`. Defaults to the front tab."],
                    "query": ["type": "string",
                             "description": "Case-insensitive substring to narrow a large page to matching lines."]
                ]
            ],
            run: { args, context, done in
                withTab(args, context, done) { controller in
                    let query = (args["query"] as? String) ?? ""
                    controller.webView.callAsyncJavaScript(
                        snapshotScript, arguments: ["query": query], in: nil, in: agentWorld) { result in
                        switch result {
                        case .failure(let error):
                            done(.failure(AgentError(error.localizedDescription)))
                        case .success(let value):
                            let text = (value as? String) ?? "(no interactive elements)"
                            done(.success([.text(describe(controller) + "\n" + text)]))
                        }
                    }
                }
            }
        ),

        AgentTool(
            name: "click",
            description: "Click an element by the ref number from the last snapshot.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "ref": ["type": "integer", "description": "Element ref from the last snapshot."],
                    "tab": ["type": "integer", "description": "Tab id from `tabs`. Defaults to the front tab."]
                ],
                "required": ["ref"]
            ],
            run: { args, context, done in
                guard let ref = argInt(args["ref"]) else {
                    done(.failure(AgentError("ref must be a number — call snapshot first")))
                    return
                }
                withTab(args, context, done) { controller in
                    let urlBefore = controller.webView.url
                    controller.webView.callAsyncJavaScript(
                        clickScript, arguments: ["ref": ref], in: nil, in: agentWorld) { result in
                        if case .failure(let error) = result {
                            done(.failure(AgentError(error.localizedDescription)))
                            return
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            finishAction(controller, urlBefore: urlBefore, done: done)
                        }
                    }
                }
            }
        ),

        AgentTool(
            name: "type",
            description: """
                Type text into an element by ref (from snapshot): inputs, textareas, selects and \
                contenteditable elements. Set submit to press Enter / submit the form afterwards.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "ref": ["type": "integer", "description": "Element ref from the last snapshot."],
                    "text": ["type": "string"],
                    "submit": ["type": "boolean",
                              "description": "Press Enter / submit the form after typing. Default false."],
                    "tab": ["type": "integer", "description": "Tab id from `tabs`. Defaults to the front tab."]
                ],
                "required": ["ref", "text"]
            ],
            run: { args, context, done in
                guard let ref = argInt(args["ref"]) else {
                    done(.failure(AgentError("ref must be a number — call snapshot first")))
                    return
                }
                guard let text = args["text"] as? String else {
                    done(.failure(AgentError("text must be a string")))
                    return
                }
                let submit = (args["submit"] as? Bool) ?? false
                withTab(args, context, done) { controller in
                    let urlBefore = controller.webView.url
                    controller.webView.callAsyncJavaScript(
                        typeScript, arguments: ["ref": ref, "text": text, "submit": submit],
                        in: nil, in: agentWorld) { result in
                        if case .failure(let error) = result {
                            done(.failure(AgentError(error.localizedDescription)))
                            return
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            finishAction(controller, urlBefore: urlBefore, done: done)
                        }
                    }
                }
            }
        ),

        AgentTool(
            name: "evaluate",
            description: """
                Run JavaScript on the page for anything the other tools don't cover — scrolling, \
                history.back(), reading attributes. js is the body of an async function: use return \
                for a value, await is allowed.
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "js": ["type": "string", "description": "Body of an async function; return a value, await allowed."],
                    "tab": ["type": "integer", "description": "Tab id from `tabs`. Defaults to the front tab."]
                ],
                "required": ["js"]
            ],
            run: { args, context, done in
                guard let js = args["js"] as? String else {
                    done(.failure(AgentError("js must be a string")))
                    return
                }
                withTab(args, context, done) { controller in
                    controller.webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                        switch result {
                        case .failure(let error):
                            done(.failure(AgentError(error.localizedDescription)))
                        case .success(let value):
                            done(.success([.text(describeJSValue(value))]))
                        }
                    }
                }
            }
        ),

        AgentTool(
            name: "screenshot",
            description: "PNG screenshot of the tab's last painted frame. Background tabs may be stale.",
            inputSchema: [
                "type": "object",
                "properties": ["tab": ["type": "integer", "description": "Tab id from `tabs`. Defaults to the front tab."]]
            ],
            run: { args, context, done in
                withTab(args, context, done) { controller in
                    controller.webView.takeSnapshot(with: nil) { image, error in
                        guard let image else {
                            done(.failure(AgentError(error?.localizedDescription ?? "could not capture a screenshot")))
                            return
                        }
                        var rect = CGRect(origin: .zero, size: image.size)
                        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
                              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                            done(.failure(AgentError("could not encode the screenshot as PNG")))
                            return
                        }
                        done(.success([.text(describe(controller)), .image(pngBase64: png.base64EncodedString())]))
                    }
                }
            }
        ),

        AgentTool(
            name: "close",
            description: "Close a tab.",
            inputSchema: [
                "type": "object",
                "properties": ["tab": ["type": "integer", "description": "Tab id from `tabs` to close."]],
                "required": ["tab"]
            ],
            run: { args, context, done in
                guard let id = argInt(args["tab"]) else {
                    done(.failure(AgentError("tab is required")))
                    return
                }
                guard let controller = context.tabs().first(where: { $0.agentTabID == id }) else {
                    done(.failure(AgentError("no such tab #\(id) — call tabs")))
                    return
                }
                controller.window?.close()
                done(.success([.text("closed #\(id)")]))
            }
        )
    ]

    /// Handed to the client at `initialize` so a model knows the loop.
    static let instructions = """
        Rocket is the user's own macOS browser with their logged-in sessions. Loop: call tabs \
        to see what is open; open/navigate to load a page and wait for it; read for the page's \
        text; snapshot to list clickable/typeable elements as [ref] lines; click/type to act by \
        ref; refs reset on every snapshot and whenever the page navigates, so snapshot again \
        after the page changes; evaluate to run JavaScript for anything else (scrolling, \
        history.back, reading attributes); screenshot when layout matters. Incognito windows are \
        never visible here.
        """

    // MARK: - Page scripts
    //
    // Each is the body of an async function; `callAsyncJavaScript` turns the `arguments`
    // dictionary into locals of the same name. Raw strings (`#"""..."""#`) so the JS's own
    // backslashes (regex, `\s+`) and quotes need no escaping.

    /// Lists the page's interactive elements and rebuilds `window.__rocketRefs`, the table
    /// `click`/`type` index into. Every visible match is pushed to the ref table regardless
    /// of `query` — `query` only trims which *lines* are printed — so a ref a model already
    /// saw from an unfiltered snapshot still resolves after a filtered one.
    private static let snapshotScript = #"""
        const SEL = 'a[href], button, input, select, textarea, summary, h1, h2, h3, [role="button"], [role="link"], [role="checkbox"], [role="radio"], [role="tab"], [role="menuitem"], [role="option"], [role="textbox"], [role="combobox"], [contenteditable=""], [contenteditable="true"], [onclick]';

        function isVisible(el) {
            if (el.matches('input[type=hidden]')) { return false; }
            return el.checkVisibility
                ? el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
                : el.getClientRects().length > 0;
        }

        function roleOf(el) {
            const explicit = el.getAttribute('role');
            if (explicit) { return explicit; }
            const tag = el.tagName.toLowerCase();
            if (tag === 'a') { return 'link'; }
            if (tag === 'button') { return 'button'; }
            if (tag === 'input') { return 'input:' + (el.getAttribute('type') || 'text'); }
            if (tag === 'select') { return 'select'; }
            if (tag === 'textarea') { return 'textarea'; }
            if (tag === 'summary') { return 'summary'; }
            if (tag === 'h1' || tag === 'h2' || tag === 'h3') { return 'heading'; }
            const editable = el.getAttribute('contenteditable');
            if (editable === '' || editable === 'true') { return 'editable'; }
            return 'clickable';
        }

        function labelOf(el) {
            const collapse = (s) => (s || '').replace(/\s+/g, ' ').trim();
            let label = collapse(el.getAttribute('aria-label'));
            if (!label && el.labels && el.labels[0]) { label = collapse(el.labels[0].textContent); }
            if (!label) { label = collapse(el.textContent); }
            if (!label) { label = collapse(el.getAttribute('placeholder')); }
            if (!label) { label = collapse(el.getAttribute('title')); }
            if (!label) {
                const img = el.querySelector('img[alt]');
                if (img) { label = collapse(img.getAttribute('alt')); }
            }
            if (!label) { label = collapse(el.getAttribute('name')); }
            const type = (el.getAttribute('type') || '').toLowerCase();
            if (!label && (el.tagName === 'BUTTON' || ['button', 'submit', 'reset'].includes(type))) {
                label = collapse(el.value);
            }
            return label.slice(0, 80);
        }

        window.__rocketRefs = [];
        const lines = [];
        Array.from(document.querySelectorAll(SEL)).filter(isVisible).forEach((el) => {
            const ref = window.__rocketRefs.length;
            window.__rocketRefs.push(el);
            let line = '[' + ref + '] ' + roleOf(el) + ' "' + labelOf(el) + '"';
            if (el.tagName === 'A' && el.hasAttribute('href')) {
                line += ' href=' + el.href.slice(0, 120);
            }
            const isPassword = el.tagName === 'INPUT' && (el.getAttribute('type') || '').toLowerCase() === 'password';
            const value = (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') ? el.value : '';
            if (!isPassword && value) {
                line += ' value="' + String(value).slice(0, 80) + '"';
            } else {
                const placeholder = el.getAttribute('placeholder');
                if (placeholder) { line += ' placeholder="' + placeholder.slice(0, 80) + '"'; }
            }
            if ((el.type === 'checkbox' || el.type === 'radio') && el.checked) { line += ' checked'; }
            if (el.disabled) { line += ' disabled'; }
            if (/^h[123]$/i.test(el.tagName)) { line += ' (' + el.tagName.toUpperCase() + ')'; }
            lines.push(line);
        });

        let shown = lines;
        if (query) {
            const needle = query.toLowerCase();
            shown = lines.filter((line) => line.toLowerCase().includes(needle));
        }
        if (!shown.length) { return '(no interactive elements)'; }
        if (shown.length > 400) {
            const extra = shown.length - 400;
            shown = shown.slice(0, 400);
            shown.push('[+' + extra + ' more — pass query to narrow]');
        }
        return shown.join('\n');
        """#

    // ponytail: synthetic click (isTrusted=false); upgrade to a native NSEvent at the
    // element rect if a site ignores it.
    private static let clickScript = #"""
        const el = (window.__rocketRefs || [])[ref];
        if (!el || !el.isConnected) { throw new Error('stale ref ' + ref + ' — call snapshot again'); }
        el.scrollIntoView({ block: 'center', inline: 'center' });
        if (typeof el.focus === 'function') { el.focus(); }
        if (typeof el.click === 'function') {
            el.click();
        } else {
            el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, composed: true }));
        }
        return 'ok';
        """#

    private static let typeScript = #"""
        const el = (window.__rocketRefs || [])[ref];
        if (!el || !el.isConnected) { throw new Error('stale ref ' + ref + ' — call snapshot again'); }
        if (typeof el.focus === 'function') { el.focus(); }

        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') {
            const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, text);
            el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
        } else if (el.tagName === 'SELECT') {
            const needle = text.toLowerCase();
            const options = Array.from(el.options);
            let match = options.find((o) => o.value === text || o.textContent.trim() === text);
            if (!match) {
                match = options.find((o) => o.value.toLowerCase() === needle || o.textContent.trim().toLowerCase() === needle);
            }
            if (!match) {
                throw new Error('no option matching "' + text + '" — options: ' + options.map((o) => o.textContent.trim()).join(', '));
            }
            el.value = match.value;
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
        } else {
            const editable = el.getAttribute('contenteditable');
            if (editable === '' || editable === 'true') {
                if (!document.execCommand('insertText', false, text)) {
                    el.textContent = text;
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                }
            } else {
                throw new Error('ref ' + ref + ' is not typeable (' + el.tagName.toLowerCase() + ')');
            }
        }

        if (submit) {
            const make = (type) => new KeyboardEvent(type, {
                key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true
            });
            const notPrevented = el.dispatchEvent(make('keydown'));
            el.dispatchEvent(make('keypress'));
            el.dispatchEvent(make('keyup'));
            if (notPrevented && el.form) {
                el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
            }
        }
        return 'ok';
        """#
}
