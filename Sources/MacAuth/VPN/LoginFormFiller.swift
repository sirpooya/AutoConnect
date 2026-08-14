import Foundation
import MacAuthCore
import WebKit

/// Fills the identity provider's login form: username, then password, then the one-time code.
///
/// Two rules shape the whole design.
///
/// **Never fail closed.** The IdP's markup is not ours and can change without notice. Every step
/// is best-effort; if a field cannot be found the window simply stays open for the user to finish
/// by hand. Autofill is a convenience layered on a working manual path, never a replacement.
///
/// **Never type a secret into an unexpected page.** The password is only ever sent to an origin
/// reached by following redirects from the gateway's own login URL, over HTTPS. If the flow lands
/// somewhere unrecognised, filling stops rather than guessing.
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
    /// Origins the password may be typed into, accumulated from the redirect chain.
    private var trustedHosts: Set<String>
    /// Steps already attempted, so a page that does not advance is not filled in a loop.
    private var attempts: [Step: Int] = [:]

    /// Maximum tries per step before giving up and leaving it to the user.
    private let maxAttemptsPerStep = 2

    /// Called when autofill has given up, so the caller can stop hiding anything from the user.
    var onGiveUp: ((String) -> Void)?

    init(credentials: Credentials, initialHost: String?) {
        self.credentials = credentials
        self.trustedHosts = Set([initialHost].compactMap { $0 })
    }

    /// Records a host as part of the login flow. Called for each navigation that begins at the
    /// gateway's login URL, so the IdP's own domain becomes trusted without being hardcoded.
    func trust(host: String?) {
        guard let host, !host.isEmpty else { return }
        trustedHosts.insert(host.lowercased())
    }

    func isTrusted(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return trustedHosts.contains(host)
    }

    // MARK: - Driving the form

    /// Inspects the page and fills whichever field it is asking for.
    ///
    /// Safe to call after every navigation and after every DOM change: it is idempotent per step
    /// and does nothing once a step has been satisfied.
    func advance(in webView: WKWebView) async {
        guard let url = webView.url, url.scheme == "https" else { return }
        guard isTrusted(host: url.host) else {
            onGiveUp?("Sign-in moved to \(url.host ?? "an unknown host"), so autofill stopped.")
            return
        }

        guard let shape = await scan(webView) else { return }

        // A reported error means the value we supplied was rejected. Retrying it verbatim would
        // just burn attempts, so hand over immediately.
        if shape.error {
            onGiveUp?("The sign-in page reported an error, so autofill stopped.")
            return
        }

        // OTP first: it is the most specific, and some IdPs render it as a password field.
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
        let used = attempts[step, default: 0]
        guard used < maxAttemptsPerStep else {
            onGiveUp?("Could not complete the \(step.rawValue) step automatically.")
            return
        }
        attempts[step] = used + 1

        // JSON-encode so quotes, backslashes and non-ASCII in a password cannot break out of the
        // expression or corrupt the value.
        guard let encoded = Self.jsonString(value) else { return }

        let script = "window.__macauth.fill(\(Self.jsonString(step.rawValue) ?? "\"\"\"\""), \(encoded))"
        _ = try? await webView.evaluateJavaScript(script)
    }

    private func scan(_ webView: WKWebView) async -> FormShape? {
        let raw = try? await webView.evaluateJavaScript(
            "JSON.stringify(window.__macauth ? window.__macauth.scan() : null)"
        )

        guard let json = raw as? String, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FormShape.self, from: data)
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
    window.__macauth = (function () {
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
                if (!visible(node) && node.offsetParent === null) continue;
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
