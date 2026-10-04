import Foundation
import Security
import Testing

@testable import ZenticKit

// MARK: - Parsing

@Suite("Threat list parsing")
struct ThreatParsingTests {
    @Test func readsEveryHostsFileShapeAndNothingElse() {
        let text = """
            # Title: Phishing Hosts Blocklist
            0.0.0.0 Login.Evil.example
            127.0.0.1\tbank-verify.example.   # trailing dot, trailing comment
            bare.example
            0.0.0.0 0.0.0.0
            127.0.0.1 localhost
            ::1 localhost
            0.0.0.0 login.evil.example
            0.0.0.0 evil.example/path
            0.0.0.0 *.wildcard.example
            0.0.0.0 two words.example
            0.0.0.0 nodots
            0.0.0.0 ..dots.example
            1.2.3.4 not-a-sinkhole.example
            """
        #expect(ThreatFeed.hosts(in: text) == ["login.evil.example", "bank-verify.example", "bare.example"])
    }

    /// Each host becomes a content-blocker regex, so anything that could
    /// change the regex's meaning must be refused at the parser.
    @Test func refusesAnythingThatIsNotAPlainHostname() {
        for hostile in ["evil.example)|(.*", "evil.example[", "a+.example", "evil.example\\", "ex ample.com", "évil.example"] {
            #expect(ThreatFeed.normalised(hostile) == nil, "\(hostile)")
        }
    }
}

// MARK: - Matching

@Suite("Threat matching")
struct ThreatMatchingTests {
    let set = ThreatSet(hosts: [
        .phishing: ["evil.example", "login.shared-host.example", "both.example"],
        .malware: ["192.0.2.7", "both.example"],
    ])

    @Test func coversSubdomainsOfAListedHost() {
        #expect(set.match(host: "evil.example") == ThreatMatch(kind: .phishing, listedHost: "evil.example"))
        #expect(set.match(host: "secure.login.evil.example") == ThreatMatch(kind: .phishing, listedHost: "evil.example"))
        #expect(set.match(host: "EVIL.example.") == ThreatMatch(kind: .phishing, listedHost: "evil.example"))
    }

    /// A phishing page on one subdomain must not condemn the whole host.
    @Test func doesNotCoverTheParentOfAListedHost() {
        #expect(set.match(host: "shared-host.example") == nil)
        #expect(set.match(host: "www.shared-host.example") == nil)
        #expect(set.match(host: "login.shared-host.example")?.kind == .phishing)
    }

    @Test func matchesWholeLabelsOnly() {
        #expect(set.match(host: "notevil.example") == nil)
        #expect(set.match(host: "evil.example.attacker.test") == nil)
    }

    @Test func treatsAnAddressAsOneThing() {
        #expect(set.match(host: "192.0.2.7")?.kind == .malware)
        #expect(set.match(host: "10.192.0.2.7") == nil)
        #expect(ThreatSet.candidates(for: "192.0.2.7") == ["192.0.2.7"])
    }

    @Test func reportsMalwareAheadOfPhishing() {
        #expect(set.match(host: "both.example")?.kind == .malware)
    }

    @Test func boundsTheParentsWalked() {
        let candidates = ThreatSet.candidates(for: "a.b.c.d.e.f.g.example")
        #expect(candidates.count == 5)
        #expect(candidates.first == "a.b.c.d.e.f.g.example")
        #expect(candidates.last == "g.example")
        // Never the bare top-level domain.
        #expect(ThreatSet.candidates(for: "evil.example") == ["evil.example"])
    }
}

// MARK: - Rules

@Suite("Threat content rules")
struct ThreatRulesTests {
    @Test func compilesOneThirdPartyBlockPerHost() throws {
        let json = ThreatRules.json(hosts: ["evil.example", "bad host", "x.example"])
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(rules.count == 2)
        let trigger = try #require(rules[0]["trigger"] as? [String: Any])
        #expect(trigger["load-type"] as? [String] == ["third-party"])
        let filter = try #require(trigger["url-filter"] as? String)
        #expect(filter == #"^[^:]+://+([^:/]+\.)?evil\.example[:/]"#)

        // The filter, read as a regex, means what it says.
        let regex = try Regex(filter)
        #expect("https://evil.example/a.js".contains(regex))
        #expect("https://cdn.evil.example:8443/a.js".contains(regex))
        #expect(!"https://evilxexample/a.js".contains(regex))
        #expect(!"https://notevil.example/a.js".contains(regex))
        #expect(!"https://evil.example.org/a.js".contains(regex))
    }
}

// MARK: - Refresh

@Suite("Threat list refresh")
struct ThreatRefreshTests {
    let directory = URL.temporaryDirectory.appending(path: "zentic-threats-\(UUID().uuidString)")

    @Test func revalidatesWithTheStoredETag() async throws {
        let fetcher = FeedStub()
        await fetcher.serve("malware", .updated(text: "0.0.0.0 malware.example", etag: "m1"))
        await fetcher.serve("phishing", .updated(text: "0.0.0.0 phish.example", etag: "p1"))
        let lists = ThreatLists(directory: directory, fetcher: fetcher)

        let first = try #require(try await lists.refresh())
        #expect(first.set.match(host: "malware.example")?.kind == .malware)
        #expect(first.set.match(host: "phish.example")?.kind == .phishing)
        #expect(await lists.isStale() == false)

        await fetcher.serve("malware", .notModified)
        await fetcher.serve("phishing", .notModified)
        #expect(try await lists.refresh() == nil)
        #expect(await fetcher.etags == ["threats.malware": "m1", "threats.phishing": "p1"])

        // A forced update asks for the whole list again.
        #expect(try await lists.refresh(force: true) == nil)
        #expect(await fetcher.etags == ["threats.malware": nil, "threats.phishing": nil])
    }

    /// A relaunch reads what the last run downloaded, with no network.
    @Test func survivesARelaunch() async throws {
        let fetcher = FeedStub()
        await fetcher.serve("malware", .updated(text: "0.0.0.0 malware.example", etag: nil))
        await fetcher.serve("phishing", .updated(text: "0.0.0.0 phish.example", etag: nil))
        let downloaded = try #require(try await ThreatLists(directory: directory, fetcher: fetcher).refresh())

        let relaunched = ThreatLists(directory: directory, fetcher: FeedStub())
        let read = try #require(await relaunched.snapshot())
        #expect(read.set == downloaded.set)
        #expect(read.contentID == downloaded.contentID)
        #expect(Set(await relaunched.allHosts()) == ["malware.example", "phish.example"])
    }

    /// One feed down must neither lose the other's update nor wipe its own
    /// last good copy — and an empty download is a failure, not an all-clear.
    @Test func keepsTheLastGoodCopyOfAFeedThatFails() async throws {
        let fetcher = FeedStub()
        await fetcher.serve("malware", .updated(text: "0.0.0.0 malware.example", etag: nil))
        await fetcher.serve("phishing", .updated(text: "0.0.0.0 phish.example", etag: nil))
        let lists = ThreatLists(directory: directory, fetcher: fetcher)
        let first = try #require(try await lists.refresh())

        await fetcher.fail("malware")
        await fetcher.serve("phishing", .updated(text: "0.0.0.0 phish.example\n0.0.0.0 phish2.example", etag: nil))
        let second = try #require(try await lists.refresh())
        #expect(second.set.match(host: "malware.example")?.kind == .malware)
        #expect(second.set.match(host: "phish2.example")?.kind == .phishing)
        #expect(second.contentID != first.contentID)

        await fetcher.serve("malware", .updated(text: "<html>Service Unavailable</html>", etag: nil))
        await fetcher.fail("phishing")
        await #expect(throws: ThreatLists.RefreshError.self) { try await lists.refresh() }
        #expect(await lists.snapshot()?.set.match(host: "malware.example")?.kind == .malware)
    }

    @Test func isStaleUntilEveryFeedHasBeenChecked() async throws {
        let fetcher = FeedStub()
        await fetcher.serve("malware", .updated(text: "0.0.0.0 malware.example", etag: nil))
        await fetcher.fail("phishing")
        let lists = ThreatLists(directory: directory, fetcher: fetcher)
        _ = try await lists.refresh()
        #expect(await lists.isStale())
        #expect(await lists.snapshot()?.checkedAt == nil)
    }
}

private actor FeedStub: FilterListFetching {
    private var responses: [String: FilterListFetchResult?] = [:]
    private(set) var etags: [String: String?] = [:]

    func serve(_ id: String, _ result: FilterListFetchResult) { responses["threats.\(id)"] = .some(result) }
    func fail(_ id: String) { responses["threats.\(id)"] = .some(nil) }

    func fetch(_ source: FilterListSource, etag: String?) async throws -> FilterListFetchResult {
        etags[source.id] = .some(etag)
        guard let result = responses[source.id] ?? nil else {
            throw BlockerError.downloadFailed(list: source.id, message: "offline")
        }
        return result
    }
}

// MARK: - Certificates

/// Real certificates, evaluated by the real `SecTrust`: a test root, a leaf
/// it issued for `zentic.test` (valid 2025-01-01 to 2026-12-31), and a
/// self-signed twin of that leaf. Generated once with OpenSSL; the keys were
/// thrown away.
@Suite("Certificate problems")
struct CertificateTests {
    static let root = certificate("MIIBZjCCAQ2gAwIBAgIBATAKBggqhkjOPQQDAjAbMRkwFwYDVQQDDBBaZW50aWMgVGVzdCBSb290MB4XDTI0MDEwMTAwMDAwMFoXDTM0MDEwMTAwMDAwMFowGzEZMBcGA1UEAwwQWmVudGljIFRlc3QgUm9vdDBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABODv+B5dMf+KhOwhZfbKQ79RMrF5QWeFJ0QeBsMydYw1PE+U7i6D0BSubQsIQlGGCX8ooM1PvLulyxCRqB11GCKjQjBAMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBTx+eg4berpfcNwcguNxHM/wAcHJjAKBggqhkjOPQQDAgNHADBEAiA5of4tWse7CP1knQQ/GOMTxT0OC9ACJH3JNybZ5nf0gQIgaljZC5Y6WP3kBzwr8Yy8xNtEqY8nbYAac78DgB5l/T0=")
    static let leaf = certificate("MIIBrTCCAVKgAwIBAgIBAjAKBggqhkjOPQQDAjAbMRkwFwYDVQQDDBBaZW50aWMgVGVzdCBSb290MB4XDTI1MDEwMTAwMDAwMFoXDTI2MTIzMTAwMDAwMFowFjEUMBIGA1UEAwwLemVudGljLnRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARzxOGZMF59pNaoSBakYI6LYLN3OcZd+3aYTIBj2YAi2qPVSZBS8CtCYI1JfqVeLtgnYp6HzYZNyXEBrsKoiMI4o4GLMIGIMAkGA1UdEwQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMBMBYGA1UdEQQPMA2CC3plbnRpYy50ZXN0MB0GA1UdDgQWBBRktz6MahBnsN0NK/HgDn5UZv2XhzAfBgNVHSMEGDAWgBTx+eg4berpfcNwcguNxHM/wAcHJjAKBggqhkjOPQQDAgNJADBGAiEA6sRtULxGay8cKLgsHtFZuHjoYwLBWm1udNTUmA/avxICIQC28vKnXz/s9wRQBJAA7ldL7FqfbXmBWRW8aSy703vOSw==")
    static let selfSigned = certificate("MIIBhDCCASqgAwIBAgIBAzAKBggqhkjOPQQDAjAWMRQwEgYDVQQDDAt6ZW50aWMudGVzdDAeFw0yNTAxMDEwMDAwMDBaFw0yNjEyMzEwMDAwMDBaMBYxFDASBgNVBAMMC3plbnRpYy50ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEc8ThmTBefaTWqEgWpGCOi2CzdznGXft2mEyAY9mAItqj1UmQUvArQmCNSX6lXi7YJ2Keh82GTclxAa7CqIjCOKNpMGcwCQYDVR0TBAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwFgYDVR0RBA8wDYILemVudGljLnRlc3QwHQYDVR0OBBYEFGS3PoxqEGew3Q0r8eAOflRm/ZeHMAoGCCqGSM49BAMCA0gAMEUCIQDQmly7yrOwXSR5XniTrCSGcB0Zi01EPxr8Br4YpgubqwIgOmICiYsjenTBf7KmZqDdLloo0pgfNZJa/Css1FJNpw4=")

    static let midValidity = ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!

    @Test func aValidChainIsNoProblem() {
        #expect(check(host: "zentic.test") == nil)
    }

    @Test func tellsTheProblemsApart() throws {
        #expect(check(host: "bank.example")?.problem == .wrongHost)
        #expect(check(host: "zentic.test", at: date("2027-06-01"))?.problem == .expired)
        #expect(check(host: "zentic.test", at: date("2024-06-01"))?.problem == .notYetValid)
        #expect(check(host: "zentic.test", anchored: false)?.problem == .untrustedIssuer)
        #expect(check(host: "zentic.test", chain: [Self.selfSigned], anchored: false)?.problem == .selfSigned)
    }

    @Test func describesTheCertificateForTheErrorPage() throws {
        let check = try #require(check(host: "bank.example"))
        #expect(check.names == ["zentic.test"])
        #expect(check.subject == "zentic.test")
        #expect(check.issuer == "Zentic Test Root")
        #expect(check.notAfter == date("2026-12-31"))
        #expect(check.problem.canBypass)
    }

    /// The exception is for a certificate, not a host: a different
    /// certificate on the same host — the attack — is asked about again.
    @Test func anExceptionCoversOneCertificateOnOneHost() throws {
        let leaf = CertificateCheck.fingerprint(of: Self.leaf)
        let twin = CertificateCheck.fingerprint(of: Self.selfSigned)
        #expect(leaf != twin)
        #expect(leaf.count == 64)

        var exceptions = CertificateExceptions()
        exceptions.accept(leaf, for: "Zentic.test")
        #expect(exceptions.permits(leaf, for: "zentic.test"))
        #expect(!exceptions.permits(twin, for: "zentic.test"))
        #expect(!exceptions.permits(leaf, for: "other.test"))
        #expect(!exceptions.hasAny(for: "other.test"))
    }

    @Test func revokedCannotBeBypassed() {
        #expect(CertificateCheck.classify(status: errSecCertificateRevoked, selfIssued: false, chainLength: 2) == .revoked)
        #expect(!CertificateProblem.revoked.canBypass)
    }

    private func check(
        host: String, at date: Date = midValidity, chain: [SecCertificate] = [leaf], anchored: Bool = true
    ) -> CertificateCheck? {
        var trust: SecTrust?
        SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
        guard let trust else { return nil }
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetVerifyDate(trust, date as CFDate)
        if anchored {
            SecTrustSetAnchorCertificates(trust, [Self.root] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        return CertificateCheck(trust: trust)
    }

    private func date(_ day: String) -> Date {
        ISO8601DateFormatter().date(from: day + "T00:00:00Z")!
    }

    private static func certificate(_ base64: String) -> SecCertificate {
        SecCertificateCreateWithData(nil, Data(base64Encoded: base64)! as CFData)!
    }
}
