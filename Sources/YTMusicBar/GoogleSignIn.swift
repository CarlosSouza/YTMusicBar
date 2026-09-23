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
    private static let signInURL = URL(string: """
        https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true\
        &continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue\
        %26app%3Ddesktop%26hl%3Dpt-BR%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F
        """.replacingOccurrences(of: "\n", with: ""))!

    @Published private(set) var isPresenting = false

    private var window: NSWindow?
    private var webView: WKWebView?
    private var onCookies: ((String) -> Void)?

    /// Opens the sign-in window; `onCookies` receives the cookie header once a session exists.
    func present(onCookies: @escaping (String) -> Void) {
        guard !isPresenting else { return }
        self.onCookies = onCookies
        isPresenting = true

        let store = WKWebsiteDataStore.default().httpCookieStore
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        store.add(self)
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
        webView?.configuration.websiteDataStore.httpCookieStore.remove(self)
        window?.orderOut(nil)
        window = nil
        webView = nil
        onCookies = nil
        isPresenting = false
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
        Task { @MainActor in await self.captureIfSignedIn() }
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
