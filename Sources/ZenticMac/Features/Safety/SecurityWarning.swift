import Foundation
import WebKit
import ZenticKit

/// A page Zentic stopped before it loaded, shown as a native warning in
/// place of the page.
enum SecurityWarning: Equatable {
    case dangerous(ThreatWarning)
    case certificate(CertificateWarning)

    var url: URL {
        switch self {
        case .dangerous(let warning): warning.url
        case .certificate(let warning): warning.url
        }
    }
}

extension Tab {
    /// "Go Back": the page underneath is still the one the user came from,
    /// because the warned-about load never committed. With nothing
    /// underneath — a link opened from Mail into a new tab — the tab goes.
    ///
    /// A tab restored at launch onto a listed site has history but nothing
    /// on screen: it steps back to the entry before, as Back would.
    func leaveWarning() {
        securityWarning = nil
        guard let webView, webView.url == nil || webView.backForwardList.currentItem == nil else { return }
        if webView.canGoBack { webView.goBack() } else { browser?.close(self) }
    }

    /// "Visit This Site Anyway": remember the choice for this run of the app,
    /// then load the page for real.
    func proceedPastWarning() {
        guard let warning = securityWarning else { return }
        switch warning {
        case .dangerous(let threat): SafeBrowsing.shared.visitAnyway(threat)
        case .certificate(let certificate):
            guard certificate.check.problem.canBypass else { return }
            CertificateTrust.shared.accept(certificate)
        }
        load(warning.url)
    }

    /// Whether the page on screen was loaded over a certificate the user
    /// accepted anyway. The address bar keeps saying so.
    var isOnCertificateException: Bool {
        guard url?.scheme == "https", let host = url?.host() else { return false }
        return CertificateTrust.shared.exceptions.hasAny(for: host)
    }

    /// The certificate to show for the page on screen, or the refused one
    /// while its error page is up. None under a dangerous-site warning: the
    /// web view still holds the previous site's, which would be shown under
    /// the listed site's name.
    var serverTrust: SecTrust? {
        switch securityWarning {
        case .certificate(let warning): warning.trust
        case .dangerous: nil
        case nil: url?.scheme == "https" ? webView?.serverTrust : nil
        }
    }

    /// Whether Page › Show Certificate… has anything to show. Observable
    /// state only, so the menu item updates without the menu being reopened.
    var canShowCertificate: Bool {
        switch securityWarning {
        case .certificate: true
        case .dangerous: false
        case nil: url?.scheme == "https"
        }
    }

    /// Look for password or card fields on a page served over plain HTTP, so
    /// the address bar can warn that what is typed there travels unencrypted.
    /// Only for `http:` pages, which are rare: every other page costs nothing.
    func checkForInsecureForm() {
        guard url?.scheme == "http", let webView else { return }
        let page = url
        Task {
            let found = await (try? webView.callAsyncJavaScript(
                #"return !!document.querySelector('input[type=password], input[autocomplete~="cc-number"], input[autocomplete~="current-password"]')"#,
                in: nil, contentWorld: .defaultClient)) as? Bool
            guard url == page else { return }
            hasInsecureForm = found == true
        }
    }
}
