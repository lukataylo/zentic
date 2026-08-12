import Foundation
import Testing

@testable import ZenticKit

/// Guards the promise that recipe inference never sees what the user is reading.
///
/// ``DOMSkeleton`` documents that it carries structure but no page text. A
/// documented promise decays: someone debugging a stubborn selector adds a
/// `sampleText` field "just for now", it ships, and the privacy claim in the
/// README quietly becomes false. So the field set is asserted here, and adding
/// anything that could hold content fails this test.
@Suite("Privacy contract")
struct PrivacyContractTests {

    /// Every key a skeleton node is permitted to encode.
    ///
    /// Adding a key here is a deliberate act. Before doing so: could this field
    /// ever contain characters from the page? If yes, it does not belong in a
    /// skeleton — put it in ``ExtractionResult`` instead, which stays on-device.
    static let allowedNodeKeys: Set<String> = [
        "tag", "id", "classes", "role", "path", "depth",
        "textLength", "linkCount", "paragraphCount", "area", "hiddenOnNarrow",
    ]

    static let allowedSkeletonKeys: Set<String> = [
        "origin", "pathPattern", "viewport", "nodes",
    ]

    @Test("A skeleton node encodes only structural fields")
    func nodeFieldsAreStructuralOnly() throws {
        let node = SkeletonNode(
            tag: "article",
            id: "main",
            classes: ["prose"],
            role: "main",
            path: "body>article",
            depth: 2,
            textLength: 1234,
            linkCount: 3,
            paragraphCount: 9,
            area: 500_000,
            hiddenOnNarrow: false
        )

        let data = try ZenticCoding.makeEncoder().encode(node)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let unexpected = Set(object.keys).subtracting(Self.allowedNodeKeys)

        #expect(
            unexpected.isEmpty,
            """
            SkeletonNode gained field(s) \(unexpected.sorted()).
            A skeleton must never carry page text — see DOMSkeleton's privacy contract.
            If the field is structural, add it to PrivacyContractTests.allowedNodeKeys.
            """
        )
    }

    @Test("A skeleton encodes only structural fields")
    func skeletonFieldsAreStructuralOnly() throws {
        let data = try ZenticCoding.makeEncoder().encode(Sample.skeleton)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let unexpected = Set(object.keys).subtracting(Self.allowedSkeletonKeys)

        #expect(unexpected.isEmpty, "DOMSkeleton gained field(s) \(unexpected.sorted())")
    }

    @Test("Text is measured, never carried")
    func textLengthIsANumber() throws {
        let data = try ZenticCoding.makeEncoder().encode(Sample.skeleton)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nodes = try #require(object["nodes"] as? [[String: Any]])
        let first = try #require(nodes.first)

        #expect(first["textLength"] is NSNumber)
        #expect(!(first["textLength"] is String))
    }
}
