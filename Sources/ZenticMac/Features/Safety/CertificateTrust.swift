import AppKit
import Foundation
import Observation
import SecurityInterface
import WebKit
import ZenticKit

/// Server-trust challenges, and the certificates the user chose to accept
/// anyway for this run of the app.
///
/// Never accepts on its own: a certificate is only trusted here after a person
/// pressed "Visit This Site Anyway" on the error page for that exact
/// certificate on that exact host.
@MainActor
@Observable
final class CertificateTrust {
    static let shared = CertificateTrust()

    private(set) var exceptions = CertificateExceptions()

    func accept(_ warning: CertificateWarning) {
        exceptions.accept(warning.check.fingerprint, for: warning.host)
    }

    func forgetExceptions() { exceptions = CertificateExceptions() }

    /// The answer to a challenge. Every host without an exception — all of
    /// them, nearly always — gets WebKit's own handling at once, with no
    /// evaluation, so ordinary browsing pays nothing for this.
    func respond(to challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
            exceptions.hasAny(for: space.host)
        else { return (.performDefaultHandling, nil) }

        // A certificate that turns out to be valid needs no exception.
        guard let check = await CertificateCheck.evaluate(trust), check.problem.canBypass,
            exceptions.permits(check.fingerprint, for: space.host)
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// The error page for a load WebKit refused over its certificate, or nil
    /// if `error` is not that.
    nonisolated static func warning(for error: NSError) async -> CertificateWarning? {
        guard isCertificateError(error), let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
            let object = error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey]
        else { return nil }
        let trust = object as! SecTrust
        guard let check = await CertificateCheck.evaluate(trust) else { return nil }
        return CertificateWarning(url: url, check: check, trust: trust)
    }

    nonisolated static func isCertificateError(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && certificateErrors.contains(error.code)
    }

    private nonisolated static let certificateErrors: Set<Int> = [
        NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
        NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot,
    ]

    /// The system's certificate sheet: the chain, each certificate's
    /// details, and why it failed — the same one Safari shows.
    private static var certificatePanel: SFCertificateTrustPanel?

    static func show(_ trust: SecTrust, for host: String, in window: NSWindow?) {
        let panel = SFCertificateTrustPanel()
        // Held until the next one: AppKit does not retain a sheet's panel.
        certificatePanel = panel
        panel.setInformativeText("Zentic can’t verify the identity of “\(host)”.")
        if let window {
            panel.beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, message: host)
        } else {
            panel.runModal(for: trust, message: host)
        }
    }
}

/// A page load refused because its certificate could not be verified.
struct CertificateWarning: Equatable {
    var url: URL
    var check: CertificateCheck
    var trust: SecTrust

    var host: String { url.host() ?? "" }

    static func == (a: Self, b: Self) -> Bool { a.url == b.url && a.check == b.check }
}
