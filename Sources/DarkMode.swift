import Cocoa
import WebKit

/// Dark pages for sites that ship no dark theme, made by rewriting their CSS rather than
/// inverting the rendered page.
///
/// An inversion filter flips photos, video and logos along with everything else, and
/// then has to flip them back, which never quite works. This reads the colours out of
/// the page's own stylesheets instead and writes a second stylesheet with the same
/// selectors and new colours: backgrounds darkened, text lightened, borders dimmed, with
/// hue and saturation kept so a brand's blue button is still blue. Images, video, canvas
/// and `url()` backgrounds are never touched, because nothing ever rewrites them.
///
/// How it stays correct:
/// - **Same selectors, appended last.** Every override rule copies the original's
///   selector, so it has the original's specificity and wins only against the rule it
///   replaces; `@media`, `@supports` and named `@layer` blocks are reproduced around it
///   so cascade order between rules is unchanged. Hover and focus colours keep working,
///   since `:hover` rules are rewritten like any other — the reason this is not done by
///   pinning computed colours onto elements.
/// - **Variables get a copy per role.** `--primary` may be a button's background and a
///   link's text at once, which no single new value can serve. So each colour variable
///   gets `--rd-bg--primary`, `--rd-text--primary` and `--rd-border--primary`, and each
///   colour property that reads a variable is rewritten to read its role's copy, falling
///   back to the original when the copy does not exist.
/// - **Pages that are already dark are left alone.** The web view's appearance is set
///   to dark, so a site with its own `prefers-color-scheme` theme shows that; the script
///   then samples the page's real background and stops if it is already dark.
/// - **Cross-origin stylesheets are fetched natively.** A CDN stylesheet without CORS
///   headers cannot be read from the page, so the script asks `StyleSheetFetcher` for
///   its text over an ephemeral session (no cookies).
///
/// It runs in an isolated content world, so pages can neither post to the fetcher nor
/// override the DOM prototypes it relies on.
enum DarkMode {

    /// Opt-in like `RestoreSession`: it changes how every website looks.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "ForceDarkMode") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "ForceDarkMode") }
    }

    /// Sites that are always dark, as `siteKey`s. A site covers its subdomains.
    static var sites: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "DarkModeSites") ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "DarkModeSites") }
    }

    /// The host a per-site choice is stored under: lowercased, minus a leading `www.`.
    static func siteKey(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty,
              url?.scheme == "https" || url?.scheme == "http" else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The listed site that covers this URL, if any.
    static func listedSite(for url: URL?) -> String? {
        guard let key = siteKey(for: url) else { return nil }
        return sites.first { key == $0 || key.hasSuffix("." + $0) }
    }

    static func applies(to url: URL?) -> Bool { isEnabled || listedSite(for: url) != nil }

    static let handlerName = "rocketDark"
    static var world: WKContentWorld { WKContentWorld.world(name: "RocketDark") }

    /// Called from `ContentBlocker.apply`, which has just wiped every user script. The
    /// script goes in whenever any site could want it and decides per frame from the
    /// top-level host, because user scripts belong to a web view, not to a site.
    static func apply(to webView: WKWebView) {
        let userContent = webView.configuration.userContentController
        userContent.removeScriptMessageHandler(forName: handlerName, contentWorld: world)
        updateAppearance(of: webView)
        let sites = self.sites
        guard isEnabled || !sites.isEmpty else { return }
        let config = try? JSONSerialization.data(withJSONObject: ["all": isEnabled, "sites": sites.sorted()])
        let source = script.replacingOccurrences(of: "__CONFIG__",
                                                 with: config.map { String(decoding: $0, as: UTF8.self) } ?? "{}")
        userContent.addScriptMessageHandler(StyleSheetFetcher.shared, contentWorld: world, name: handlerName)
        userContent.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false, in: world))
    }

    /// Sites with a dark theme of their own pick it up through prefers-color-scheme.
    /// Re-run on every commit, since a tab moves between sites that differ.
    static func updateAppearance(of webView: WKWebView) {
        webView.appearance = applies(to: webView.url) ? NSAppearance(named: .darkAqua) : nil
    }

    /// Which stylesheet URLs the fetcher will load. A page chooses its stylesheet links,
    /// and the override sheet built from a fetched one is readable by the page, so this
    /// keeps that from becoming a way to read files off the local network.
    /// ponytail: literal hosts only — a public name resolving to a private address
    /// still passes; resolve and re-check if that ever matters.
    static func mayFetch(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), host.contains("."), !host.contains(":"),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost") else { return false }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return true }
        switch (octets[0], octets[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
        case (172, 16...31), (100, 64...127): return false
        default: return true
        }
    }

    static let script = #"""
    (function () {
        'use strict';
        if (window.__rocketDark || !(document instanceof HTMLDocument)) { return; }
        window.__rocketDark = true;
        // The top-level page decides, so a listed site's embeds go dark with it.
        const config = __CONFIG__, origins = location.ancestorOrigins;
        let host = location.hostname;
        try { if (origins && origins.length) { host = new URL(origins[origins.length - 1]).hostname; } } catch (e) {}
        host = host.toLowerCase().replace(/^www\./, '');
        if (!config.all && !(config.sites || []).some(s => host === s || host.endsWith('.' + s))) { return; }
        const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.rocketDark;

        // --- colour ---------------------------------------------------------------
        function toHsl(r, g, b) {
            r /= 255; g /= 255; b /= 255;
            const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2;
            if (max === min) { return [0, 0, l]; }
            const d = max - min, s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
            const h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
            return [h / 6, s, l];
        }
        function toRgb(h, s, l) {
            if (s === 0) { return [l * 255, l * 255, l * 255]; }
            const q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
            function hue(t) {
                if (t < 0) { t += 1; } if (t > 1) { t -= 1; }
                if (t < 1 / 6) { return p + (q - p) * 6 * t; }
                if (t < 1 / 2) { return q; }
                if (t < 2 / 3) { return p + (q - p) * (2 / 3 - t) * 6; }
                return p;
            }
            return [hue(h + 1 / 3) * 255, hue(h) * 255, hue(h - 1 / 3) * 255];
        }
        // Lightness curves; hue and saturation are kept. Backgrounds: light goes dark,
        // dark stays dark. Text: dark goes light, light stays light. Borders sit between.
        const CURVE = {
            bg: l => l > 0.5 ? 0.1 + (1 - l) * 0.6 : l * 0.8,
            border: l => l > 0.5 ? 0.15 + (1 - l) * 0.5 : 0.15 + l * 0.5,
            text: l => l < 0.5 ? 0.92 - l * 0.44 : 0.7 + (l - 0.5) * 0.44
        };
        function shift(c, role) {
            if (c[3] === 0) { return null; }
            const hsl = toHsl(c[0], c[1], c[2]);
            // A faint wash (hover tint, zebra stripe) is a tint against the page, not a
            // surface: flip it so it still shows on a dark page.
            const l = role === 'bg' && c[3] < 0.5 ? 1 - hsl[2] : CURVE[role](hsl[2]);
            const out = toRgb(hsl[0], hsl[1], l).map(Math.round);
            out.push(c[3]);
            return out;
        }
        function fmt(c) {
            return c[3] >= 1 ? 'rgb(' + c[0] + ', ' + c[1] + ', ' + c[2] + ')'
                             : 'rgba(' + c[0] + ', ' + c[1] + ', ' + c[2] + ', ' + c[3] + ')';
        }

        // A canvas parses every CSS colour syntax for us and reads back as hex or rgba().
        const ctx = document.createElement('canvas').getContext('2d');
        const KEYWORD = /^(currentcolor|inherit|initial|unset|revert|revert-layer|transparent|none)$/i;
        const parsed = new Map();
        function parse(text) {
            text = text.trim();
            if (parsed.has(text)) { return parsed.get(text); }
            let c = null, m;
            if (text && !KEYWORD.test(text) && !/var\(|calc\(|env\(|attr\(/i.test(text)) {
                ctx.fillStyle = '#010203';
                ctx.fillStyle = text;
                const v = ctx.fillStyle;
                if (v[0] === '#' && (v !== '#010203' || /^#010203$/i.test(text))) {
                    c = [parseInt(v.slice(1, 3), 16), parseInt(v.slice(3, 5), 16), parseInt(v.slice(5, 7), 16), 1];
                } else if ((m = /^rgba\((\d+), (\d+), (\d+), ([\d.]+)\)$/.exec(v))) {
                    c = [+m[1], +m[2], +m[3], +m[4]];
                }
            }
            parsed.set(text, c);
            return c;
        }

        const TOKEN = /#[0-9a-f]{3,8}\b|(?:rgb|hsl)a?\([^()]*\)|\b(?:white|black)\b/gi;
        // Colours inside a longer value (gradients), leaving url(...) alone.
        function convertTokens(text, role) {
            const urls = [];
            return text.replace(/url\([^)]*\)/gi, u => '\u0000' + (urls.push(u) - 1) + '\u0000')
                .replace(TOKEN, t => { const c = parse(t), s = c && shift(c, role); return s ? fmt(s) : t; })
                .replace(/\u0000(\d+)\u0000/g, (_, i) => urls[i]);
        }

        // rgb(255 255 255 / var(--tw-bg-opacity)): the channels are literal, the alpha is not.
        const LOOSE_RGB = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)\s*[,/]\s*(.+)\)$/i;
        const converted = new Map();
        function convert(value, role) {
            const key = role + value;
            if (converted.has(key)) { return converted.get(key); }
            let out, m;
            if ((m = LOOSE_RGB.exec(value)) && /var\(|calc\(/i.test(m[4])) {
                const c = shift([+m[1], +m[2], +m[3], 1], role);
                out = 'rgb(' + c[0] + ' ' + c[1] + ' ' + c[2] + ' / ' + m[4] + ')';
            } else if (/gradient\(/i.test(value)) {
                out = convertTokens(value, role);
            } else {
                const c = parse(value), s = c && shift(c, role);
                out = s && fmt(s);
            }
            if (out === value) { out = null; }
            converted.set(key, out);
            return out;
        }

        // var(--x, fb) -> var(--rd-ROLE--x, var(--x, fb')), so an undefined copy falls
        // back to the original instead of making the property invalid.
        function rewriteVars(value, role) {
            let out = '', i = 0;
            for (;;) {
                const at = value.indexOf('var(', i);
                if (at < 0) { return out + convertTokens(value.slice(i), role); }
                let depth = 0, end = at + 3;
                for (; end < value.length; end++) {
                    if (value[end] === '(') { depth++; } else if (value[end] === ')' && --depth === 0) { break; }
                }
                const inner = value.slice(at + 4, end), comma = inner.indexOf(',');
                const name = (comma < 0 ? inner : inner.slice(0, comma)).trim();
                let fallback = comma < 0 ? '' : inner.slice(comma + 1).trim();
                if (fallback) {
                    fallback = ', ' + (fallback.indexOf('var(') >= 0 ? rewriteVars(fallback, role)
                                                                    : (convert(fallback, role) || fallback));
                }
                out += convertTokens(value.slice(i, at), role) + (name.startsWith('--')
                    ? 'var(--rd-' + role + name + ', var(' + name + fallback + '))'
                    : value.slice(at, end + 1));
                i = end + 1;
            }
        }

        // --- declarations ------------------------------------------------------------
        const PROPS = {
            'background-color': 'bg', 'background-image': 'bg',
            'color': 'text', 'fill': 'text', 'stroke': 'text', 'caret-color': 'text',
            'text-decoration-color': 'text', '-webkit-text-fill-color': 'text',
            'border-top-color': 'border', 'border-right-color': 'border',
            'border-bottom-color': 'border', 'border-left-color': 'border',
            'border-block-start-color': 'border', 'border-block-end-color': 'border',
            'border-inline-start-color': 'border', 'border-inline-end-color': 'border',
            'outline-color': 'border', 'column-rule-color': 'border'
        };
        const ROLES = ['bg', 'text', 'border'];
        const TRIPLET = /^(\d{1,3})(\s*,\s*|\s+)(\d{1,3})\2(\d{1,3})$/;              // 255 255 255
        const HSL_TRIPLET = /^(-?[\d.]+)(?:deg)?\s+([\d.]+)%\s+([\d.]+)%$/;          // 0 0% 100% (shadcn)
        const COLORISH = /^(#|rgba?\(|hsla?\(|hwb\(|lab\(|lch\(|oklab\(|oklch\(|color\(|[a-z]+$)/i;

        // The role-specific copies of one custom property, as [name, value] pairs.
        function variants(name, value) {
            value = value.trim();
            const out = [];
            let t, h;
            for (const role of ROLES) {
                let next = null;
                if (value.indexOf('var(') >= 0) {
                    next = rewriteVars(value, role);
                } else if ((t = TRIPLET.exec(value))) {
                    const c = shift([+t[1], +t[3], +t[4], 1], role);
                    next = [c[0], c[1], c[2]].join(t[2]);
                } else if ((h = HSL_TRIPLET.exec(value))) {
                    const rgb = toRgb(h[1] / 360, h[2] / 100, h[3] / 100);
                    const c = shift([rgb[0], rgb[1], rgb[2], 1], role), o = toHsl(c[0], c[1], c[2]);
                    next = (o[0] * 360).toFixed(1) + ' ' + (o[1] * 100).toFixed(1) + '% ' + (o[2] * 100).toFixed(1) + '%';
                } else if (COLORISH.test(value)) {
                    next = convert(value, role);
                }
                if (next) { out.push(['--rd-' + role + name, next]); }
            }
            return out;
        }

        // A shorthand holding var() leaves its longhands empty in the CSSOM, so
        // `background: var(--bg)` is only visible on `background` itself.
        function shorthandOf(name, style) {
            const parts = name.replace(/-color$/, '').split('-'), tries = [];
            for (let n = parts.length; n >= 1; n--) { tries.push(parts.slice(0, n).join('-')); }
            if (parts[0] === 'border') { tries.splice(tries.length - 1, 0, 'border-color'); }
            return tries.find(t => style.getPropertyValue(t));
        }

        // Every replacement a declaration block needs, as [property, value, priority].
        function replacements(style, skip) {
            const out = [], seen = new Set();
            for (const name of Array.from(style)) {
                if (name.startsWith('--rd-')) { continue; }
                let prop = name, value = style.getPropertyValue(name);
                const priority = style.getPropertyPriority(name);
                if (name.startsWith('--')) {
                    if (skip && skip(name, value)) { continue; }
                    for (const pair of variants(name, value)) { out.push([pair[0], pair[1], priority]); }
                    if (skip) { skip(name, value, true); }
                    continue;
                }
                let role = PROPS[name];
                if (!role) { continue; }
                if (!value) {
                    prop = shorthandOf(name, style);
                    if (!prop || seen.has(prop)) { continue; }
                    seen.add(prop);
                    value = style.getPropertyValue(prop);
                    role = prop === 'background' ? 'bg' : 'border';
                }
                if (skip && skip(prop, value)) { continue; }
                const next = value.indexOf('var(') >= 0 ? rewriteVars(value, role) : convert(value, role);
                if (next && next !== value) { out.push([prop, next, style.getPropertyPriority(prop) || priority]); }
            }
            return out;
        }

        // --- stylesheets --------------------------------------------------------------
        const remote = new Map();
        function sheetRules(sheet) {
            try { return sheet.cssRules; } catch (e) {}
            const href = sheet.href;
            if (!href || !bridge) { return null; }
            const got = remote.get(href);
            if (got === undefined) {
                remote.set(href, null);
                bridge.postMessage(href).then(text => {
                    if (!text) { return; }
                    const s = new CSSStyleSheet();
                    try { s.replaceSync(text); } catch (e) { return; }
                    remote.set(href, s);
                    schedule(0);
                }, () => {});
            }
            return got ? got.cssRules : null;
        }

        function header(rule) {
            if (rule.type === CSSRule.MEDIA_RULE) { return '@media ' + rule.media.mediaText; }
            if (rule.type === CSSRule.SUPPORTS_RULE) { return '@supports ' + rule.conditionText; }
            if (typeof CSSLayerBlockRule !== 'undefined' && rule instanceof CSSLayerBlockRule) { return '@layer ' + rule.name; }
            const text = rule.cssText;
            return text.slice(0, text.indexOf('{'));
        }
        function wrapMedia(media, css) {
            const m = media && media.mediaText;
            return css && m && m !== 'all' ? '@media ' + m + '{' + css + '}' : css;
        }
        function emit(rules) {
            let css = '';
            for (const rule of rules) {
                if (rule.type === CSSRule.STYLE_RULE) {
                    let body = '';
                    for (const r of replacements(rule.style)) { body += r[0] + ':' + r[1] + (r[2] ? '!important;' : ';'); }
                    if (rule.cssRules && rule.cssRules.length) { body += emit(rule.cssRules); }
                    if (body) { css += rule.selectorText + '{' + body + '}'; }
                } else if (rule.type === CSSRule.IMPORT_RULE) {
                    const inner = rule.styleSheet && sheetRules(rule.styleSheet);
                    if (inner) { css += wrapMedia(rule.media, emit(inner)); }
                } else if (rule.cssRules && rule.type !== CSSRule.KEYFRAMES_RULE) {
                    const inner = emit(rule.cssRules);
                    if (inner) { css += header(rule) + '{' + inner + '}'; }
                }
            }
            return css;
        }

        // Ours is one adopted sheet: adopted sheets cascade after every document sheet,
        // and a constructed sheet is not an inline <style> that a page's CSP can block.
        const sheet = new CSSStyleSheet();
        const BASE = ':root{color-scheme:dark!important}:where(:root){background-color:' + fmt(shift([255, 255, 255, 1], 'bg'))
            + ';color:' + fmt(shift([0, 0, 0, 1], 'text')) + '}:where(a:link){color:#8ab4f8}';
        sheet.replaceSync(BASE);
        function adopt() {
            const list = document.adoptedStyleSheets;
            if (list[list.length - 1] !== sheet) { document.adoptedStyleSheets = list.filter(s => s !== sheet).concat(sheet); }
        }
        adopt();

        let signature = '';
        function rebuild() {
            adopt();
            const all = Array.from(document.styleSheets).concat(document.adoptedStyleSheets.filter(s => s !== sheet));
            const sig = all.map(s => { const r = sheetRules(s); return (s.disabled ? 'd' : '') + (r ? r.length : '-') + (s.href || ''); }).join('|');
            if (sig === signature) { return; }
            signature = sig;
            let css = BASE;
            for (const s of all) {
                const rules = !s.disabled && sheetRules(s);
                if (rules) { css += wrapMedia(s.media, emit(rules)); }
            }
            try { sheet.replaceSync(css); } catch (e) {}
        }

        // --- inline styles ----------------------------------------------------------------
        // Values this script wrote, per element, so its own writes are not converted twice.
        const written = new WeakMap();
        function writtenBy(el) {
            let mine = written.get(el);
            if (!mine) { written.set(el, mine = new Map()); }
            return mine;
        }
        // Old markup colours with attributes, not CSS (Hacker News is tables and
        // bgcolor). They are converted into inline style; the attribute stays as is.
        const ATTRS = [['bgcolor', 'background-color', 'bg', null], ['color', 'color', 'text', 'FONT'],
                       ['text', 'color', 'text', 'BODY']];
        function fixAttributes(el) {
            for (const [attr, prop, role, tag] of ATTRS) {
                if ((tag && el.nodeName !== tag) || !el.hasAttribute(attr) || el.style.getPropertyValue(prop)) { continue; }
                const raw = el.getAttribute(attr).trim();
                const next = convert(/^[0-9a-f]{6}$/i.test(raw) ? '#' + raw : raw, role);
                if (!next) { continue; }
                el.style.setProperty(prop, next);
                writtenBy(el).set(prop, el.style.getPropertyValue(prop));
            }
        }
        const COLORED = '[style], [bgcolor], font[color], body[text]';
        function fixElement(el) {
            if (el.hasAttribute('bgcolor') || el.hasAttribute('color') || el.hasAttribute('text')) { fixAttributes(el); }
            fixInline(el);
        }
        function fixInline(el) {
            const style = el.style;
            if (!style || !style.length) { return; }
            const mine = writtenBy(el);
            const skip = (prop, value, done) => {
                if (done) { mine.set(prop, value); return false; }
                return mine.get(prop) === value;
            };
            for (const r of replacements(style, skip)) {
                style.setProperty(r[0], r[1], r[2]);
                if (!r[0].startsWith('--')) { mine.set(r[0], style.getPropertyValue(r[0])); }
            }
        }

        // --- lifecycle ------------------------------------------------------------------
        let timer = 0, started = false, stopped = false;
        function schedule(delay) {
            if (!timer && !stopped) { timer = setTimeout(() => { timer = 0; rebuild(); }, delay); }
        }
        const observer = new MutationObserver(records => {
            let styles = false;
            for (const r of records) {
                if (r.type === 'attributes') {
                    if (r.attributeName !== 'style') { styles = true; } else if (started) { fixInline(r.target); }
                    continue;
                }
                if (r.target.nodeName === 'STYLE') { styles = true; }
                for (const n of r.addedNodes) {
                    if (n.nodeType !== 1) { continue; }
                    if (n.nodeName === 'STYLE' || n.nodeName === 'LINK') { styles = true; }
                    if (started) {
                        if (n.matches(COLORED)) { fixElement(n); }
                        n.querySelectorAll(COLORED).forEach(fixElement);
                    }
                }
            }
            schedule(styles ? 0 : 250);
        });
        observer.observe(document, { childList: true, subtree: true, attributes: true,
                                     attributeFilter: ['style', 'class', 'media', 'disabled', 'rel'] });
        const onLoad = e => { if (e.target.nodeName === 'LINK') { schedule(0); } };
        document.addEventListener('load', onLoad, true);

        // Judged on the page's own colours, with ours switched off: what is under the
        // middle of the viewport, else the canvas colour the page's color-scheme gives.
        function pageIsDark() {
            sheet.disabled = true;
            try {
                let el = document.elementFromPoint(innerWidth / 2, innerHeight / 2) || document.body;
                for (; el; el = el.parentElement) {
                    const c = parse(getComputedStyle(el).backgroundColor);
                    if (c && c[3] > 0.5) { return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255 < 0.4; }
                }
                return /dark/.test(getComputedStyle(document.documentElement).colorScheme)
                    && matchMedia('(prefers-color-scheme: dark)').matches;
            } finally {
                sheet.disabled = false;
            }
        }

        function start() {
            rebuild();
            if (pageIsDark()) {
                stopped = true;
                clearTimeout(timer);
                observer.disconnect();
                document.removeEventListener('load', onLoad, true);
                document.adoptedStyleSheets = document.adoptedStyleSheets.filter(s => s !== sheet);
                return;
            }
            started = true;
            document.querySelectorAll(COLORED).forEach(fixElement);
        }
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', start, { once: true });
        } else {
            start();
        }
    })();
    """#
}

/// Fetches the text of cross-origin stylesheets the page cannot read itself. Ephemeral,
/// so no cookies ride along; only `text/css` comes back, capped at 4 MB.
final class StyleSheetFetcher: NSObject, WKScriptMessageHandlerWithReply {

    static let shared = StyleSheetFetcher()
    private let session = URLSession(configuration: .ephemeral)

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let string = message.body as? String, let url = URL(string: string),
              DarkMode.mayFetch(url) else {
            replyHandler(nil, "refused")
            return
        }
        session.dataTask(with: url) { data, response, _ in
            var text: String?
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               http.mimeType == "text/css", let data, data.count <= 4_000_000 {
                text = String(decoding: data, as: UTF8.self)
            }
            DispatchQueue.main.async { replyHandler(text, nil) }
        }.resume()
    }
}
