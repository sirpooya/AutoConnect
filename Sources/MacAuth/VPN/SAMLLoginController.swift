import AppKit
import MacAuthCore
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

    // MARK: - Window

    private func presentWindow() {
        let configuration = WKWebViewConfiguration()
        // Persistent, so the IdP remembers this browser between launches.
        configuration.websiteDataStore = .default()

        if filler != nil {
            // Injected at document end on every frame, since IdPs commonly render the form inside
            // one. The script only reads shape and applies values it is handed; it carries no
            // secret of its own.
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: LoginFormFiller.userScript,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: false
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

        webView.load(URLRequest(url: authRequest.loginURL))
    }

    private func dismissWindow() {
        guard window != nil else { return }

        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        webView?.navigationDelegate = nil
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
            continuation?.resume(returning: token)
        case .failure(let error):
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
        // The cookie may be set before the nominated final URL is reached, so check on every
        // completed navigation rather than only at the end.
        checkForToken()

        guard let filler else { return }

        // Every host reached by following the gateway's own login URL is part of the flow, so the
        // IdP's domain becomes trusted here rather than being hardcoded.
        filler.trust(host: webView.url?.host)

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
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
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
            return completionHandler(.performDefaultHandling, nil)
        }

        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        guard let leaf = chain.first else {
            return completionHandler(.cancelAuthenticationChallenge, nil)
        }

        let fingerprint = GatewayClient.sha1Fingerprint(of: leaf)
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
