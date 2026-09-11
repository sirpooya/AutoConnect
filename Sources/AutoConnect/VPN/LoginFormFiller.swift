import Foundation
import AutoConnectCore
import WebKit

/// Fills the identity provider's login form: username, then password, then the one-time code.
///
/// Two rules shape the whole design.
///
/// **Never fail closed.** The IdP's markup is not ours and can change without notice. Every step
/// is best-effort; if a field cannot be found the window simply stays open for the user to finish
/// by hand. Autofill is a convenience layered on a working manual path, never a replacement.
///
/// **Never type a secret into an unexpected page.** The password is only ever sent, over HTTPS, to
/// the gateway or to the identity provider it handed off to. `LoginOriginPolicy` owns that
/// decision and holds it to two anchors; if the flow lands anywhere else, filling stops rather
/// than guessing.
///
/// The scanner and filler run in `WKContentWorld.defaultClient`, not in the page's own JavaScript
/// world. The page shares the DOM with that world but not its globals, so it cannot reach
/// `window.__autoconnect` or redefine the setter the fill goes through. Running in the page's
/// world meant the password was passed as an argument to a function the page itself could replace.
@MainActor
final class LoginFormFiller {

    /// What the page is currently asking for, as reported by the injected scanner.
    struct FormShape: Decodable, Equatable {
        var username = false
        var password = false
        var otp = false
        /// True when the page appears to be reporting a rejected credential, so a retry with the
        /// same values would be pointless.
        var error = false
    }

    enum Step: String {
        case username
        case password
        case otp
    }

    /// Values to fill. The one-time code is a closure so it is generated at the moment it is
    /// needed: a code fetched seconds earlier may already have expired.
    struct Credentials {
        var username: String
        var password: String?
        var oneTimeCode: () -> String?
    }

    private let credentials: Credentials
    /// Which origins a secret may be typed into. Two anchors, not a growing set: see
    /// `LoginOriginPolicy`.
    private var origins: LoginOriginPolicy
    /// Steps already attempted, so a page that does not advance is not filled in a loop.
    private var attempts: [Step: Int] = [:]

    /// The world the injected script lives in. Isolated from the page, so a hostile or merely
    /// compromised page in the sign-in chain cannot replace `fill` and read what it is handed.
    static let contentWorld: WKContentWorld = .defaultClient

    /// Maximum tries per step before giving up and leaving it to the user.
    private let maxAttemptsPerStep = 2

    /// Called when autofill has given up, so the caller can stop hiding anything from the user.
    var onGiveUp: ((String) -> Void)? {
        didSet {
            // Wrap whatever the caller set, so every give-up is recorded regardless of who asked.
            let handler = onGiveUp
            guard handler != nil, !isWrappingGiveUp else { return }
            isWrappingGiveUp = true
            onGiveUp = { reason in
                DiagnosticLog.write("autofill: gave up, \(reason)")
                handler?(reason)
            }
            isWrappingGiveUp = false
        }
    }

    private var isWrappingGiveUp = false

    /// True once autofill has put a value into any field this session.
    private var hasAttemptedAnything: Bool { !attempts.isEmpty }

    init(credentials: Credentials, initialHost: String?) {
        self.credentials = credentials
        self.origins = LoginOriginPolicy(gatewayHost: initialHost)
    }

    /// Records a host the flow has reached, so the identity provider's own domain becomes
    /// trusted without being hardcoded.
    ///
    /// Learning is deliberately one-shot. Every host reached used to be added to a set that only
    /// grew, and `isTrusted` was then asked about the host that had *just* been added, so the
    /// check could never fail: a single open redirect anywhere in the chain was enough to have
    /// the password typed into the page it pointed at.
    func trust(host: String?) {
        origins.observe(host: host)
    }

    func isTrusted(host: String?) -> Bool {
        origins.allows(host: host)
    }

    // MARK: - Driving the form

    /// Inspects the page and fills whichever field it is asking for.
    ///
    /// Safe to call after every navigation and after every DOM change: it is idempotent per step
    /// and does nothing once a step has been satisfied.
    func advance(in webView: WKWebView) async {
        guard let url = webView.url, url.scheme == "https" else { return }
        guard isTrusted(host: url.host) else {
            DiagnosticLog.write(
                "autofill: \(url.host ?? "an unknown host") is outside the sign-in "
                    + "(\(origins.anchors.joined(separator: ", "))), so nothing was typed"
            )
            onGiveUp?("Sign-in moved to \(url.host ?? "an unknown host"), so autofill stopped.")
            return
        }

        guard let shape = await scan(webView) else {
            DiagnosticLog.write("autofill: page reported no fields at \(DiagnosticLog.redact(webView.url))")
            return
        }
        DiagnosticLog.write(
            "autofill: needs username=\(shape.username) password=\(shape.password) "
                + "otp=\(shape.otp) error=\(shape.error)"
        )

        // Decide what the page wants before judging any error on it. OTP first: it is the most
        // specific, and some identity providers render it as a password field.
        let target: Step? = shape.otp ? .otp : (shape.password ? .password : (shape.username ? .username : nil))
        guard let target else { return }

        // An error banner only condemns the step it belongs to. ADFS answers a username-only
        // submission with "Incorrect user ID or password" and then shows the password step still
        // carrying that message, so a blanket check gives up before the password is ever tried.
        // Only stop when the step now being asked for is one we already supplied a value for.
        if shape.error, attempts[target, default: 0] > 0 {
            onGiveUp?("The sign-in page rejected the \(target.rawValue), so autofill stopped.")
            return
        }

        if shape.otp {
            guard let code = credentials.oneTimeCode() else {
                onGiveUp?("No authenticator account is set for one-time codes.")
                return
            }
            await fill(.otp, value: code, in: webView)
            return
        }

        if shape.password {
            guard let password = credentials.password, !password.isEmpty else {
                onGiveUp?("No password is stored, so autofill stopped.")
                return
            }
            await fill(.password, value: password, in: webView)
            return
        }

        if shape.username {
            guard !credentials.username.isEmpty else {
                onGiveUp?("No username is set, so autofill stopped.")
                return
            }
            await fill(.username, value: credentials.username, in: webView)
        }
    }

    private func fill(_ step: Step, value: String, in webView: WKWebView) async {
        DiagnosticLog.write(
            "autofill: filling \(step.rawValue) (\(DiagnosticLog.describe(secret: value)))"
        )
        let used = attempts[step, default: 0]
        guard used < maxAttemptsPerStep else {
            onGiveUp?("Could not complete the \(step.rawValue) step automatically.")
            return
        }
        attempts[step] = used + 1

        // JSON-encode so quotes, backslashes and non-ASCII in a password cannot break out of the
        // expression or corrupt the value.
        guard let encoded = Self.jsonString(value) else { return }

        let script = "window.__autoconnect.fill(\(Self.jsonString(step.rawValue) ?? "\"\"\"\""), \(encoded))"
        _ = await evaluate(script, in: webView)
    }

    private func scan(_ webView: WKWebView) async -> FormShape? {
        let raw = await evaluate(
            "JSON.stringify(window.__autoconnect ? window.__autoconnect.scan() : null)",
            in: webView
        )

        guard let json = raw as? String, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FormShape.self, from: data)
    }

    /// Runs one expression in the world the script was injected into.
    ///
    /// The completion-handler form on purpose. Its world-taking counterpart takes the handler as a
    /// defaulted argument, so `await webView.evaluateJavaScript(script, in: nil, in: world)` binds
    /// to *that* overload and returns `Void` immediately rather than the value: the scan then
    /// decodes nothing and autofill silently stops working. Naming the handler removes the choice.
    private func evaluate(_ script: String, in webView: WKWebView) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script, in: nil, in: Self.contentWorld) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }

    private static func jsonString(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: [value],
            options: [.fragmentsAllowed]
        ),
              let array = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        // Unwrap the single-element array to get a bare JSON string literal.
        return String(array.dropFirst().dropLast())
    }

    // MARK: - Injected script

    /// Scanner and filler, injected at document end on every frame.
    ///
    /// Kept entirely in the page: Swift only asks "what do you want?" and answers with one value,
    /// so no secret is ever embedded in a script that runs before the page is identified.
    static let userScript = """
    window.__autoconnect = (function () {
        const OTP_HINT = /otp|totp|one.?time|passcode|verification|mfa|token|\\bcode\\b|otc/i;
        const USER_HINT = /user|email|mail|login|upn|account|ident/i;
        const PASS_HINT = /pass|pwd|secret/i;

        function visible(el) {
            if (el.disabled || el.readOnly) return false;
            if (el.type === 'hidden') return false;
            const rect = el.getBoundingClientRect();
            if (rect.width <= 1 || rect.height <= 1) return false;
            const style = window.getComputedStyle(el);
            return style.visibility !== 'hidden' && style.display !== 'none';
        }

        function describe(el) {
            return [
                el.name, el.id, el.getAttribute('autocomplete'),
                el.getAttribute('aria-label'), el.placeholder,
                el.getAttribute('data-testid')
            ].filter(Boolean).join(' ');
        }

        function inputs() {
            return Array.from(document.querySelectorAll('input')).filter(visible);
        }

        function classify(el) {
            const hint = describe(el);
            // Order matters: an OTP field is often type=password or type=text, so its naming
            // has to be checked before the generic buckets.
            if (OTP_HINT.test(hint)) return 'otp';
            const maxLength = el.maxLength;
            const numeric = el.inputMode === 'numeric' || /^[0-9]*$/.test(el.pattern || '');
            if (numeric && maxLength > 0 && maxLength <= 8) return 'otp';
            if (el.type === 'password') return PASS_HINT.test(hint) || !hint ? 'password' : 'password';
            if (el.type === 'email' || el.type === 'tel') return 'username';
            if (el.type === 'text' || el.type === '' || el.type === 'search') {
                return USER_HINT.test(hint) || inputs().length === 1 ? 'username' : null;
            }
            return null;
        }

        function empty(el) {
            return !el.value || el.value.length === 0;
        }

        function errorShown() {
            const nodes = document.querySelectorAll(
                '[role="alert"], .error, .alert-danger, #errorText, [class*="error"]'
            );
            for (const node of nodes) {
                // Must be genuinely laid out and painted. ADFS keeps its error element in the
                // DOM at all times, so text alone proves nothing.
                if (node.offsetParent === null) continue;
                const rect = node.getBoundingClientRect();
                if (rect.height < 1 || rect.width < 1) continue;
                const style = window.getComputedStyle(node);
                if (style.visibility === 'hidden' || style.display === 'none') continue;
                if (parseFloat(style.opacity || '1') < 0.05) continue;
                const text = (node.textContent || '').trim();
                if (text.length > 0 && text.length < 400) return true;
            }
            return false;
        }

        function scan() {
            const found = { username: false, password: false, otp: false, error: errorShown() };
            for (const el of inputs()) {
                const kind = classify(el);
                // Only unfilled fields count as something being asked for; a page that carries a
                // remembered username should not be refilled.
                if (kind && empty(el)) found[kind] = true;
            }
            return found;
        }

        function submitFor(el) {
            const form = el.form;
            if (form) {
                const button = form.querySelector(
                    'button[type=submit], input[type=submit], button:not([type])'
                );
                if (button) { button.click(); return true; }
                if (typeof form.requestSubmit === 'function') { form.requestSubmit(); return true; }
                form.submit();
                return true;
            }

            // Frameworks that skip <form> entirely: fall back to the nearest plausible button,
            // then to an Enter keypress.
            const button = document.querySelector(
                'button[type=submit], button:not([type]), input[type=submit], [role=button]'
            );
            if (button) { button.click(); return true; }

            el.dispatchEvent(new KeyboardEvent('keydown', {
                key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true
            }));
            return false;
        }

        function fill(kind, value) {
            const target = inputs().find(el => classify(el) === kind && empty(el));
            if (!target) return false;

            target.focus();
            // Assign through the native setter so React and friends see the change; setting
            // .value directly is invisible to their synthetic event system.
            const descriptor = Object.getOwnPropertyDescriptor(
                window.HTMLInputElement.prototype, 'value'
            );
            if (descriptor && descriptor.set) {
                descriptor.set.call(target, value);
            } else {
                target.value = value;
            }

            target.dispatchEvent(new Event('input', { bubbles: true }));
            target.dispatchEvent(new Event('change', { bubbles: true }));

            return submitFor(target);
        }

        return { scan: scan, fill: fill };
    })();
    """
}
