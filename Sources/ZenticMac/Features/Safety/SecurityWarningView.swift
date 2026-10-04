import SwiftUI
import ZenticKit

/// The warning a tab shows in place of a page it stopped.
struct SecurityWarningView: View {
    let tab: Tab
    let warning: SecurityWarning

    var body: some View {
        switch warning {
        case .dangerous(let threat): ThreatPage(tab: tab, threat: threat)
        case .certificate(let certificate): CertificatePage(tab: tab, warning: certificate)
        }
    }
}

private struct ThreatPage: View {
    let tab: Tab
    let threat: ThreatWarning

    var body: some View {
        let feed = threat.match.feed
        WarningPage(
            tone: .danger,
            symbol: threat.match.kind == .phishing ? "exclamationmark.shield.fill" : "xmark.shield.fill",
            title: threat.match.kind == .phishing ? "This looks like a phishing site" : "This site may harm your Mac",
            host: threat.host,
            message: message,
            footnote: "Zentic stopped it before anything loaded.",
            bypass: WarningAction(
                title: "Visit This Site Anyway (Unsafe)",
                note: "Zentic won’t warn about \(threat.host) again until you quit.",
                action: tab.proceedPastWarning),
            goBack: tab.leaveWarning
        ) {
            WarningFact(label: "Listed on", value: "\(feed.title) — \(feed.attribution)")
            if threat.match.listedHost != threat.host.lowercased() {
                WarningFact(label: "Matching entry", value: "\(threat.match.listedHost), which covers its subdomains", monospaced: false)
            }
            if let updated = threat.listUpdated {
                WarningFact(label: "List checked", value: updated.formatted(.relative(presentation: .named)))
            }
            WarningFact(
                label: "Privacy",
                value: "The address was checked against lists stored on this Mac. It was not sent anywhere.")
        }
    }

    private var message: String {
        switch threat.match.kind {
        case .phishing:
            "\(threat.host) is on a list of sites that imitate banks, shops and sign-in pages to steal passwords and card numbers. Anything typed here could end up with someone else."
        case .malware:
            "\(threat.host) is on a list of sites known to spread malware — software that can steal your data, spy on you or hold your files to ransom. Just opening the page can be enough."
        }
    }
}

private struct CertificatePage: View {
    let tab: Tab
    let warning: CertificateWarning

    private var check: CertificateCheck { warning.check }

    var body: some View {
        WarningPage(
            tone: .caution, symbol: symbol, title: title, host: warning.host, message: message,
            footnote: footnote, secondary: showCertificate, bypass: bypass, goBack: tab.leaveWarning
        ) {
            if let subject = check.subject { WarningFact(label: "Issued to", value: subject) }
            if let issuer = check.issuer { WarningFact(label: "Issued by", value: issuer) }
            if let notBefore = check.notBefore, let notAfter = check.notAfter {
                WarningFact(
                    label: "Valid",
                    value: "\(notBefore.formatted(date: .abbreviated, time: .omitted)) to \(notAfter.formatted(date: .abbreviated, time: .omitted))")
            }
            if !check.names.isEmpty {
                WarningFact(label: "Valid for", value: check.names.prefix(6).joined(separator: ", ") + (check.names.count > 6 ? ", …" : ""))
            }
            WarningFact(label: "SHA-256 fingerprint", value: Self.grouped(check.fingerprint), monospaced: true)
            if let system = check.systemMessage {
                WarningFact(label: "Reason", value: system)
            }
        }
    }

    private var symbol: String {
        switch check.problem {
        case .expired, .notYetValid: "clock.badge.exclamationmark.fill"
        default: "lock.trianglebadge.exclamationmark.fill"
        }
    }

    private var title: String {
        check.problem == .revoked ? "This site’s certificate was withdrawn" : "This connection isn’t private"
    }

    private var footnote: String? {
        guard check.problem != .revoked else { return nil }
        return "Anything you send — passwords, messages, card numbers — could be read or changed on the way."
    }

    private var showCertificate: WarningAction {
        let warning = warning
        return WarningAction(title: "Show Certificate") {
            CertificateTrust.show(warning.trust, for: warning.host, in: NSApp.keyWindow)
        }
    }

    private var bypass: WarningAction? {
        guard check.problem.canBypass else { return nil }
        return WarningAction(
            title: "Visit This Site Anyway",
            note: "Zentic will trust this certificate on \(warning.host) until you quit. If the site presents a different one, you’ll be asked again.",
            action: tab.proceedPastWarning)
    }

    private var message: String {
        let host = warning.host
        switch check.problem {
        case .expired:
            let when = check.notAfter.map { " on \($0.formatted(date: .long, time: .omitted))" } ?? ""
            return "The certificate that proves this is \(host) expired\(when). The site may have forgotten to renew it — or someone may be intercepting the connection."
        case .notYetValid:
            let when = check.notBefore.map { " until \($0.formatted(date: .long, time: .omitted))" } ?? " yet"
            return "The certificate for \(host) isn’t valid\(when). If that date looks wrong, check your Mac’s clock: it says it’s \(Date.now.formatted(date: .long, time: .omitted))."
        case .wrongHost:
            let owner = check.names.first ?? check.subject ?? "another site"
            return "The certificate here belongs to \(owner), not \(host). Someone may be impersonating the site, or it’s set up wrong."
        case .selfSigned:
            return "\(host) vouched for itself: no certificate authority has confirmed who runs it. That’s normal for a router or printer on your own network, and a warning sign anywhere else."
        case .untrustedIssuer:
            let issuer = check.issuer.map { "“\($0)”" } ?? "an authority"
            return "The certificate for \(host) was issued by \(issuer), which your Mac doesn’t trust. Someone may be intercepting the connection."
        case .revoked:
            return "The authority that issued \(host)’s certificate has withdrawn it, usually because its key was stolen or misused. Zentic won’t open this site."
        case .other:
            return "Zentic couldn’t verify the certificate for \(host), so it can’t be sure you’re talking to the real site."
        }
    }

    /// `ab12 cd34 …` reads, and can be compared by eye with what a site's
    /// owner reads out; one 64-character run cannot.
    private static func grouped(_ hex: String) -> String {
        stride(from: 0, to: hex.count, by: 4).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return String(hex[start..<(hex.index(start, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex)])
        }.joined(separator: " ")
    }
}
