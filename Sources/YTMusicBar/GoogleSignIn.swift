import AppKit
import Foundation
import WebKit

/// Google sign-in through a WKWebView owned by the app.
///
/// Copying request headers from another browser gives a snapshot, and the browser keeps rotating
/// `__Secure-3PSIDTS` underneath it, which is what made the session go stale after a while. Hosting
/// the login here lets WebKit own the cookies, so we read live values instead of a frozen copy.
@MainActor
final class GoogleSignIn: NSObject, ObservableObject, WKHTTPCookieStoreObserver {
    static let shared = GoogleSignIn()

    /// WebKit's own user agent has no Safari token and Google refuses to sign in with it.
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let host = "music.youtube.com"
    private static let authCookie = "__Secure-3PAPISID"
    /// The short-lived cookie the browser rotates every few minutes; a stale copy is what logs the
    /// session out, so a renewal is only real once this one changes.
    private static let rotationCookie = "__Secure-3PSIDTS"
    private static let signInURL = URL(string: """
        https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true\
        &continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue\
        %26app%3Ddesktop%26hl%3Dpt-BR%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F
        """.replacingOccurrences(of: "\n", with: ""))!

    @Published private(set) var isPresenting = false
    @Published private(set) var isRenewing = false

    private var window: NSWindow?
    private var webView: WKWebView?
    private var onCookies: ((String) -> Void)?
    private var renewWebView: WKWebView?
    private var renewWaiter: CheckedContinuation<Void, Never>?
    private var renewTimeout: Task<Void, Never>?
    /// The cookie the app actually depends on, captured before a renewal so a change can be spotted.
    private var renewBaseline: String?

    private override init() {
        super.init()
        WKWebsiteDataStore.default().httpCookieStore.add(self)
    }

    /// Opens the sign-in window; `onCookies` receives the cookie header once a session exists.
    func present(onCookies: @escaping (String) -> Void) {
        guard !isPresenting else { return }
        self.onCookies = onCookies
        isPresenting = true

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        webView.load(URLRequest(url: Self.signInURL))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Entrar com o Google"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        self.webView = webView

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        webView = nil
        onCookies = nil
        isPresenting = false
    }

    /// Loads YouTube Music in an offscreen web view so the page rotates the session cookies itself,
    /// then returns the fresh header. This is what keeps a stored copy from going stale.
    func refreshedCookieHeader(timeout: TimeInterval = 10) async -> String? {
        guard renewWaiter == nil, !isPresenting else { return nil }
        isRenewing = true
        renewBaseline = await cookieValue(named: Self.rotationCookie)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 900), configuration: configuration)
        webView.customUserAgent = Self.userAgent
        renewWebView = webView

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            renewWaiter = continuation
            webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
            renewTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.endRenewal()
            }
        }
        let header = await cookieHeader()
        renewWebView = nil
        isRenewing = false
        return header
    }

    private func endRenewal() {
        renewTimeout?.cancel()
        renewTimeout = nil
        renewBaseline = nil
        renewWaiter?.resume()
        renewWaiter = nil
    }

    private func cookieValue(named name: String) async -> String? {
        await WKWebsiteDataStore.default().httpCookieStore.allCookies().first { $0.name == name }?.value
    }

    /// Reads the cookies WebKit holds for the YouTube Music host, or nil when there is no session.
    func cookieHeader() async -> String? {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let now = Date()
        let matched = cookies.filter { cookie in
            Self.matches(domain: cookie.domain, host: Self.host)
                && (cookie.expiresDate.map { $0 > now } ?? true)
        }
        guard matched.contains(where: { $0.name == Self.authCookie }) else { return nil }
        return HTTPCookie.requestHeaderFields(with: matched)["Cookie"]
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in await self.cookiesChanged() }
    }

    private func cookiesChanged() async {
        guard renewWaiter == nil else {
            // A renewal is waiting; only a new rotation cookie means the page actually rotated it.
            let current = await cookieValue(named: Self.rotationCookie)
            if let current, current != renewBaseline { endRenewal() }
            return
        }
        await captureIfSignedIn()
    }

    private func captureIfSignedIn() async {
        guard let header = await cookieHeader(), let onCookies else { return }
        close()
        onCookies(header)
    }

    /// Cookie domain rules: `.youtube.com` reaches `music.youtube.com` and the bare domain does too.
    private static func matches(domain: String, host: String) -> Bool {
        let domain = domain.lowercased()
        let host = host.lowercased()
        let base = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == base || host.hasSuffix("." + base)
    }
}

extension GoogleSignIn: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in await self.captureIfSignedIn() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.close() }
    }
}
