import AppKit
import AutoConnectCore
import WebKit

/// Performs the gateway's SAML login in a `WKWebView` this app owns, and returns the token
/// cookie the gateway then trades for a session token.
///
/// This is the piece Cisco's own client makes impossible to automate: AnyConnect renders the
/// same page in an embedded webview with macOS secure input enabled, which blocks synthetic
/// keystrokes. In our own webview there is no such restriction, so B4 can fill the form.
///
/// The data store is deliberately **persistent**: the IdP's session cookie survives app
/// restarts, so a reconnect inside the IdP's own session window can skip the login entirely.
@MainActor
final class SAMLLoginController: NSObject {

    enum LoginError: LocalizedError {
        case cancelled
        case timedOut
        case tokenMissing(cookieName: String)
        case gatewayReportedError(String)
        case certificateRejected(expected: String, actual: String?)
        case navigationFailed(String)

        /// True for the failures another identical attempt cannot clear.
        ///
        /// A gateway that rejected the credentials will reject the same ones again, and every
        /// redial spends one of the corporate account's lockout attempts on a password already
        /// known to be wrong. Retrying it also builds a fresh `WKWebView` per attempt, which is
        /// what pushed WebKit into critical memory pressure on the main thread and hung the app.
        var isTerminal: Bool {
            switch self {
            case .gatewayReportedError, .certificateRejected:
                return true
            case .cancelled, .timedOut, .tokenMissing, .navigationFailed:
                return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Sign-in was cancelled."
            case .timedOut:
                return "Sign-in timed out."
            case .tokenMissing(let cookieName):
                return """
                    Sign-in finished but the gateway did not set its \(cookieName) cookie. \
                    Try again.
                    """
            case .gatewayReportedError(let message):
                return "The gateway rejected the sign-in: \(message)"
            case .certificateRejected(let expected, let actual):
                return """
                    The sign-in page presented an unexpected certificate. \
                    Expected \(expected), got \(actual ?? "none").
                    """
            case .navigationFailed(let detail):
                return "The sign-in page could not be loaded: \(detail)"
            }
        }
    }

    private let authRequest: ConfigAuth.AuthRequest
    private let profile: VPNProfile
    private let timeout: TimeInterval
    private let filler: LoginFormFiller?

    private var window: NSWindow?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var hasFinished = false

    /// Set when autofill has bowed out, so the reason can be shown next to the form instead of
    /// leaving the user wondering why nothing was typed.
    @Published private(set) var autofillNotice: String?

    /// The first host the gateway handed the login off to, which is the identity provider.
    /// Recorded so Settings can offer that site's saved password first, and for nothing else.
    private(set) var observedIdPHost: String?

    init(
        authRequest: ConfigAuth.AuthRequest,
        profile: VPNProfile,
        credentials: LoginFormFiller.Credentials? = nil,
        timeout: TimeInterval = 300
    ) {
        self.authRequest = authRequest
        self.profile = profile
        self.timeout = timeout
        self.filler = credentials.map {
            LoginFormFiller(credentials: $0, initialHost: authRequest.loginURL.host)
        }
        super.init()
    }

    /// Shows the login window and resolves with the SAML token once the gateway sets it.
    func obtainSSOToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            presentWindow()

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.timeout ?? 300))
                guard !Task.isCancelled else { return }
                self?.finish(with: .failure(LoginError.timedOut))
            }
        }
    }

    /// Abandons a sign-in that is still on screen, because something outside it has decided the
    /// connect is over.
    ///
    /// Disconnect cancels the task awaiting this login, and that alone does nothing: the task is
    /// suspended on a `CheckedContinuation` waiting for a cookie, which cancellation does not
    /// touch. So the window sat there after a disconnect with nothing left to hand its token to.
    func cancel() {
        guard !hasFinished else { return }
        DiagnosticLog.write("login: cancelled from outside, closing the sign-in window")
        finish(with: .failure(LoginError.cancelled))
    }

    // MARK: - Window

    private func presentWindow() {
        let configuration = WKWebViewConfiguration()
        // Persistent, so the IdP remembers this browser between launches.
        configuration.websiteDataStore = .default()

        if filler != nil {
            // Injected at document end on every frame, since IdPs commonly render the form inside
            // one. The script only reads shape and applies values it is handed; it carries no
            // secret of its own.
            //
            // In a client world rather than the page's own. The two share the DOM, which is all
            // the script needs, but not their globals: the page cannot see `window.__autoconnect`
            // and cannot replace `fill`. In the page world it could, and since Swift passes the
            // password to that function as an argument, replacing it was enough to read it.
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: LoginFormFiller.userScript,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: false,
                    in: LoginFormFiller.contentWorld
                )
            )
        }

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 520, height: 640),
            configuration: configuration
        )
        webView.navigationDelegate = self
        // The IdP may serve a page that expects a real browser.
        webView.customUserAgent = nil
        self.webView = webView

        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to \(profile.tunnelGroup)"
        window.contentView = webView
        window.center()
        window.delegate = self
        window.isReleasedWhenClosed = false
        self.window = window

        // A menu-bar-only app is normally not focusable, so the policy has to change or the user
        // cannot type into the form. WindowActivation counts claims and restores accessory mode.
        WindowActivation.claim()
        window.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            await purgeStaleGatewayCookies()
            self.webView?.load(URLRequest(url: self.authRequest.loginURL))
        }
    }

    /// Removes the gateway's token and error cookies before the login starts.
    ///
    /// The data store is persistent so the IdP remembers this browser, and the gateway's own
    /// cookies persist with it. A token left over from an earlier login looks exactly like one
    /// this login produced, so `checkForToken` captured it on the first navigation, before the
    /// user had signed in, and the auth-reply presented a spent token against a fresh `<opaque>`:
    /// the gateway answered "Single sign-on AnyConnect token verification failure" and every
    /// retry failed identically, because the stale cookie was still there. A stale error cookie
    /// is the same bug wearing the other outcome. Only these two are cleared; the IdP's session
    /// cookies are the whole point of a persistent store.
    private func purgeStaleGatewayCookies() async {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }

        var names: Set<String> = [authRequest.tokenCookieName]
        if let errorName = authRequest.errorCookieName { names.insert(errorName) }

        let cookies = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }

        for cookie in cookies where names.contains(cookie.name) {
            DiagnosticLog.write("login: clearing stale \(cookie.name) from a previous sign-in")
            await withCheckedContinuation { continuation in
                store.delete(cookie) { continuation.resume() }
            }
        }
    }

    private func dismissWindow() {
        guard window != nil else { return }

        window?.delegate = nil
        window?.orderOut(nil)
        window = nil

        // Stop the page before dropping the reference. Releasing a WKWebView does not promptly
        // end its WebContent process: this app has no
        // `com.apple.runningboard.assertions.webkit` entitlement, so WebKit cannot take the
        // termination watchdog assertion and a still-loading webview lingers about thirty
        // seconds. Across a run of retries they overlap, and ten of them at ~140MB each is what
        // drove WebKit into critical memory pressure on the main thread.
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
        webView?.removeFromSuperview()
        webView = nil
        // Hand back the claim taken when the window opened.
        WindowActivation.release()
    }

    private func finish(with result: Result<String, Error>) {
        guard !hasFinished else { return }
        hasFinished = true

        timeoutTask?.cancel()
        timeoutTask = nil
        dismissWindow()

        let continuation = self.continuation
        self.continuation = nil

        switch result {
        case .success(let token):
            DiagnosticLog.write("login: token captured (\(DiagnosticLog.describe(secret: token)))")
            continuation?.resume(returning: token)
        case .failure(let error):
            DiagnosticLog.write("login: finished with failure: \(error)")
            continuation?.resume(throwing: error)
        }
    }

    // MARK: - Token capture

    /// Looks for the token cookie, and for the gateway's error cookie, after every navigation.
    private func checkForToken() {
        guard let webView else { return }

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }

            Task { @MainActor in
                let names = cookies.map(\.name).sorted().joined(separator: ", ")
                DiagnosticLog.write("login: cookies present [\(names)]")

                if let errorName = self.authRequest.errorCookieName,
                   let errorCookie = cookies.first(where: { $0.name == errorName }),
                   !errorCookie.value.isEmpty
                {
                    self.finish(with: .failure(
                        LoginError.gatewayReportedError(errorCookie.value)
                    ))
                    return
                }

                if let token = cookies.first(where: { $0.name == self.authRequest.tokenCookieName }),
                   !token.value.isEmpty
                {
                    self.finish(with: .success(token.value))
                }
            }
        }
    }

    /// True once the browser has reached the URL the gateway nominated as the end of the flow.
    private func isFinalURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        // Compare without query or fragment: the gateway appends state to this URL.
        return url.host == authRequest.loginFinalURL.host
            && url.path == authRequest.loginFinalURL.path
    }
}

// MARK: - Navigation

extension SAMLLoginController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DiagnosticLog.write("login: loaded \(DiagnosticLog.redact(webView.url))")

        // The cookie may be set before the nominated final URL is reached, so check on every
        // completed navigation rather than only at the end.
        checkForToken()

        // The flow can end on a navigation that is still settling: keep typing into a webview
        // whose window has already gone and the log reads as a login continuing past its failure.
        guard !hasFinished, let filler else { return }

        // Every host reached by following the gateway's own login URL is part of the flow, so the
        // IdP's domain becomes trusted here rather than being hardcoded.
        filler.trust(host: webView.url?.host)

        // The first host that is not the gateway is the identity provider.
        if observedIdPHost == nil,
           let host = webView.url?.host,
           host != authRequest.loginURL.host {
            observedIdPHost = host
        }

        filler.onGiveUp = { [weak self] reason in
            self?.autofillNotice = reason
        }

        Task { @MainActor in
            // Single-page forms swap fields in without a navigation, so give the DOM a moment to
            // settle before deciding what the page is asking for.
            try? await Task.sleep(for: .milliseconds(350))
            await filler.advance(in: webView)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        DiagnosticLog.write(
            "login: navigating to \(DiagnosticLog.redact(navigationAction.request.url))"
        )

        // The app relaxes App Transport Security wholesale, because no gateway is known ahead of
        // time and the ones this exists for negotiate suites ATS refuses. That relaxation applies
        // to this webview too, so without a check here the sign-in would follow a plaintext hop
        // quite happily, and the token cookie the whole flow exists to collect would go on the
        // wire in the clear. The gateway is HTTPS and so is every identity provider; a redirect
        // to http:// is not a step of a sign-in worth completing.
        if navigationAction.request.url?.scheme?.lowercased() == "http" {
            decisionHandler(.cancel)
            finish(with: .failure(LoginError.navigationFailed(
                "The sign-in tried to continue over an unencrypted http:// connection, which "
                    + "would expose the session token. It was stopped."
            )))
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            DiagnosticLog.write(
                "login: response \(response.statusCode) from "
                    + "\(DiagnosticLog.redact(navigationResponse.response.url))"
            )
        }
        decisionHandler(.allow)
        if isFinalURL(navigationResponse.response.url) {
            checkForToken()
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        report(navigationError: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        report(navigationError: error)
    }

    private func report(navigationError error: Error) {
        let nsError = error as NSError
        DiagnosticLog.write(
            "login: navigation error \(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        )
        // Cancelled navigations are routine: redirects and our own teardown both produce them.
        guard nsError.code != NSURLErrorCancelled else { return }
        finish(with: .failure(LoginError.navigationFailed(error.localizedDescription)))
    }

    /// The gateway certificate has no trusted signer, so the pin is what establishes trust.
    /// The IdP is a normal public host and keeps standard system validation.
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            return completionHandler(.performDefaultHandling, nil)
        }

        // Only the gateway is pinned. Anything else goes through system trust.
        let gatewayHost = profile.host.split(separator: ":").first.map(String.init) ?? profile.host
        guard challenge.protectionSpace.host.caseInsensitiveCompare(gatewayHost) == .orderedSame,
              let expected = profile.normalizedCertificateSHA1
        else {
            DiagnosticLog.write(
                "login: system trust for \(challenge.protectionSpace.host) (not the pinned gateway)"
            )
            return completionHandler(.performDefaultHandling, nil)
        }

        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        guard let leaf = chain.first else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }

        let fingerprint = GatewayClient.sha1Fingerprint(of: leaf)
        DiagnosticLog.write(
            "login: pin check for \(challenge.protectionSpace.host) "
                + "\(fingerprint == expected ? "matched" : "MISMATCH (\(fingerprint))")"
        )
        if fingerprint == expected {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(with: .failure(
                LoginError.certificateRejected(expected: expected, actual: fingerprint)
            ))
        }
    }
}

// MARK: - Window closing

extension SAMLLoginController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        finish(with: .failure(LoginError.cancelled))
    }
}
