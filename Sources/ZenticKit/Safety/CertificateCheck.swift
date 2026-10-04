import CryptoKit
import Foundation
import Security

/// Why a server's certificate was refused, in the terms the error page uses.
///
/// WebKit reports every one of these as the same `NSURLErrorServerCertificateUntrusted`,
/// so the reason has to come from evaluating the server's `SecTrust` again.
public enum CertificateProblem: String, Sendable, Equatable {
    case expired
    case notYetValid
    /// Issued for a different name: misconfiguration, or impersonation.
    case wrongHost
    /// Signed by itself — normal for a router, suspicious for a public site.
    case selfSigned
    /// Chains to an authority this Mac does not trust.
    case untrustedIssuer
    /// The authority withdrew it. No exception is offered for this one.
    case revoked
    case other

    /// Whether "Visit Anyway" is offered. A revoked certificate was disowned
    /// by the very authority that vouched for it; there is nothing left for
    /// the user to judge.
    public var canBypass: Bool { self != .revoked }
}

/// What the error page and the certificate exception need to know about a
/// refused certificate.
///
/// Evaluating a trust can touch the network (revocation, missing
/// intermediates) and always costs real time, so build this off the main thread.
public struct CertificateCheck: Sendable, Equatable {
    public var problem: CertificateProblem
    /// The leaf's SHA-256, hex. An exception is for this certificate on this
    /// host, never for the host: if the certificate changes, the user is asked again.
    public var fingerprint: String
    public var subject: String?
    public var issuer: String?
    public var notBefore: Date?
    public var notAfter: Date?
    /// The names the certificate is valid for, for "issued for … not …".
    public var names: [String]
    /// The system's own sentence, for the details disclosure.
    public var systemMessage: String?

    /// Nil when the trust evaluates as valid.
    public init?(trust: SecTrust) {
        var error: CFError?
        guard !SecTrustEvaluateWithError(trust, &error) else { return nil }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first
        else { return nil }
        let status = error.map { OSStatus(CFErrorGetCode($0)) }

        fingerprint = Self.fingerprint(of: leaf)
        subject = SecCertificateCopySubjectSummary(leaf) as String?
        issuer = Self.commonName(of: leaf, oid: kSecOIDX509V1IssuerName)
        notBefore = SecCertificateCopyNotValidBeforeDate(leaf) as Date?
        notAfter = SecCertificateCopyNotValidAfterDate(leaf) as Date?
        names = Self.dnsNames(of: leaf)
        systemMessage = error.map { CFErrorCopyDescription($0) as String }
        problem = Self.classify(status: status, selfIssued: Self.isSelfIssued(leaf), chainLength: chain.count)
        // The Security framework says "expired" for both ends of the validity
        // window. They need different advice: one is the site's fault, the
        // other is nearly always this Mac's clock.
        let evaluatedAt = Date(timeIntervalSinceReferenceDate: SecTrustGetVerifyTime(trust))
        if problem == .expired, let notBefore, evaluatedAt < notBefore { problem = .notYetValid }
    }

    /// ``init(trust:)`` on a background thread. Evaluating can wait on the
    /// network for revocation, so it never runs on the main one.
    public static func evaluate(_ trust: SecTrust) async -> CertificateCheck? {
        // `SecTrust` is not marked Sendable, but nothing else touches this one
        // while it is evaluated: WebKit has either finished with it (a failed
        // load) or is waiting on our answer (a challenge).
        nonisolated(unsafe) let trust = trust
        return await Task.detached(priority: .userInitiated) { CertificateCheck(trust: trust) }.value
    }

    /// The order matters: a self-signed certificate for the wrong name is
    /// reported as the wrong name, because that is the part a person can
    /// check against the address bar.
    static func classify(status: OSStatus?, selfIssued: Bool, chainLength: Int) -> CertificateProblem {
        switch status {
        case errSecHostNameMismatch: .wrongHost
        case errSecCertificateExpired: .expired
        case errSecCertificateRevoked: .revoked
        case errSecNotTrusted, errSecCreateChainFailed:
            selfIssued && chainLength == 1 ? .selfSigned : .untrustedIssuer
        default:
            selfIssued && chainLength == 1 ? .selfSigned : .other
        }
    }

    public static func fingerprint(of certificate: SecCertificate) -> String {
        let data = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSelfIssued(_ certificate: SecCertificate) -> Bool {
        guard let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?,
            let subject = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?
        else { return false }
        return issuer == subject
    }

    private static func values(of certificate: SecCertificate, oid: CFString) -> Any? {
        let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [String: Any]
        return (values?[oid as String] as? [String: Any])?[kSecPropertyKeyValue as String]
    }

    private static func commonName(of certificate: SecCertificate, oid: CFString) -> String? {
        let fields = values(of: certificate, oid: oid) as? [[String: Any]] ?? []
        let field = fields.first { ($0[kSecPropertyKeyLabel as String] as? String) == (kSecOIDCommonName as String) }
        return field?[kSecPropertyKeyValue as String] as? String
    }

    private static func dnsNames(of certificate: SecCertificate) -> [String] {
        let fields = values(of: certificate, oid: kSecOIDSubjectAltName) as? [[String: Any]] ?? []
        return fields.compactMap {
            ($0[kSecPropertyKeyLabel as String] as? String) == "DNS Name" ? $0[kSecPropertyKeyValue as String] as? String : nil
        }
    }
}

/// Certificates the user chose to trust anyway, for this run of the app only.
///
/// Keyed by host *and* the leaf's fingerprint: the exception is "I have looked
/// at this certificate and accept it here", so a different certificate on the
/// same host — the attack the warning exists for — is asked about again.
public struct CertificateExceptions: Sendable {
    private var accepted: [String: Set<String>] = [:]

    public init() {}

    public mutating func accept(_ fingerprint: String, for host: String) {
        accepted[host.lowercased(), default: []].insert(fingerprint)
    }

    /// Cheap enough for every TLS challenge: most hosts have no exception,
    /// and those answer without the trust being evaluated at all.
    public func hasAny(for host: String) -> Bool { accepted[host.lowercased()] != nil }

    public func permits(_ fingerprint: String, for host: String) -> Bool {
        accepted[host.lowercased()]?.contains(fingerprint) == true
    }

    public var isEmpty: Bool { accepted.isEmpty }
    public var count: Int { accepted.count }
}
