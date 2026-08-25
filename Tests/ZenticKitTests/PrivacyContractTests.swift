import Foundation
import Testing

@testable import ZenticKit

/// Guards the promise that neither recipe inference nor lens authoring ever sees
/// what the user is reading.
///
/// ``DOMSkeleton`` and ``RegionCatalog`` both document that they carry structure
/// but no page text. A documented promise decays: someone debugging a stubborn
/// selector adds a `sampleText` field "just for now", it ships, and the privacy
/// claim in the README quietly becomes false. So the field sets are asserted
/// here, and adding anything that could hold content fails this test.
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

    // MARK: Region catalog

    /// Every key a region candidate is permitted to encode.
    ///
    /// Same rule as ``allowedNodeKeys``, and a stronger temptation to break it:
    /// op authoring reads much more naturally with a snippet of the region's
    /// text in the prompt, and that is exactly the field that must never exist.
    /// If a region cannot be identified from geometry, counts and class tokens,
    /// the segmentation is wrong — the answer is a better `kindGuess`, not a
    /// sample of what the user is reading.
    static let allowedCandidateKeys: Set<String> = [
        "id", "selector", "alternates", "tag", "elementID", "classes", "role",
        "kindGuess", "rect", "depth", "textLength", "linkCount", "paragraphCount",
        "imageCount", "itemCount", "itemSelector", "itemFields",
    ]

    /// Every key one offered harvest field is permitted to encode.
    ///
    /// The sharpest edge in the catalog. A model picks a harvest field instantly
    /// from `{selector: "h3", text: "How to make bread"}` — which is the sentence
    /// the user is reading, on the wire, to a third party. Everything a field
    /// needs to be *chosen* is here without it: what to select, what element it
    /// is, which attributes can be read off it, and how long its text runs.
    static let allowedItemFieldKeys: Set<String> = [
        "selector", "tag", "attributesPresent", "textLength",
    ]

    /// Every key a region fingerprint is permitted to encode.
    ///
    /// Same rule again, and the strongest temptation of the three, because a
    /// fingerprint's whole job is *recognising the same box later* — and a stored
    /// snippet of the region's heading would do that beautifully. It would also
    /// write what the user reads into `Lenses.json` and keep it there for good.
    ///
    /// `role` is the one attribute *value* in the set, and it is deliberate: ARIA
    /// roles are a closed W3C vocabulary picked from a fixed list, so `role` cannot
    /// hold a character from the page. `aria-label` can and does, which is why only
    /// its *name* appears, in `attributeNames`.
    static let allowedFingerprintKeys: Set<String> = [
        "tag", "elementID", "classes", "attributeNames", "role", "childCount",
        "textLengthBand", "rectBand", "siblingIndex", "ancestorTags",
    ]

    static let allowedCatalogKeys: Set<String> = [
        "origin", "pathPattern", "viewport", "candidates",
    ]

    /// Field-name fragments that mean "characters from the page".
    ///
    /// Deliberately broad, and deliberately *not* applied to the allow-listed
    /// names: `textLength` and `alternates` both contain a needle and both are
    /// fine. Anything else carrying one of these is a new field nobody has
    /// justified, which is the point at which it needs a conversation rather
    /// than a merge.
    static let proseNeedles = [
        "text", "excerpt", "label", "title", "heading", "summary", "aria",
        "placeholder", "alt", "content", "body", "snippet", "html", "word",
    ]

    /// Every key an encoded ``RegionCatalog`` — envelope included — may hold.
    static var allowedEncodedKeys: Set<String> {
        allowedCandidateKeys
            .union(allowedCatalogKeys)
            .union(allowedItemFieldKeys)
            .union(["v", "type", "payload", "x", "y", "width", "height"])
    }

    /// The check that actually holds the line.
    ///
    /// The encoded assertions below all read a *sample*, so the temptation takes
    /// the one shape they cannot see: add `var sampleText: String?` to
    /// ``RegionCandidate``, leave it nil in the sample, and `encodeIfPresent`
    /// drops it from the JSON. Every assertion passes, the field ships, and the
    /// first page that populates it puts the user's reading on the wire.
    /// `Mirror` sees what is *declared*, so nil-ness cannot hide anything.
    @Test("A region candidate declares only structural fields, nil or not")
    func candidateDeclaredFieldsAreStructuralOnly() throws {
        let candidate = try #require(LensSample.catalog.candidates.first)
        let declared = Set(Mirror(reflecting: candidate).children.compactMap(\.label))
        let unexpected = declared.subtracting(Self.allowedCandidateKeys)

        #expect(
            unexpected.isEmpty,
            """
            RegionCandidate declares field(s) \(unexpected.sorted()).
            A catalog must never carry page text — see RegionCandidate's privacy contract.
            A nil optional still counts: this test reads the declaration, not the encoding,
            precisely so that "it is only set when debugging" is not an answer.
            If the field is structural, add it to PrivacyContractTests.allowedCandidateKeys.
            """
        )
    }

    /// The same declaration-level check, one level down.
    ///
    /// ``RegionCandidate/itemFields`` is a nested type, so the check above sees
    /// only the array. Adding `var sampleText: String` to ``ItemFieldCandidate``
    /// would pass every assertion on the candidate itself and ship the user's
    /// headlines to a model. `Mirror` on the element type is what closes that.
    @Test("An offered item field declares only structural fields, nil or not")
    func itemFieldDeclaredFieldsAreStructuralOnly() throws {
        let field = try #require(
            LensSample.catalog.candidates.compactMap(\.itemFields.first).first
        )
        let declared = Set(Mirror(reflecting: field).children.compactMap(\.label))
        let unexpected = declared.subtracting(Self.allowedItemFieldKeys)

        #expect(
            unexpected.isEmpty,
            """
            ItemFieldCandidate declares field(s) \(unexpected.sorted()).
            This is the field set a model picks a harvest column from, so a sample of the
            item's text would make authoring easier and would be the user's own reading on
            the wire. Attribute *names* and a text *length*, nothing else.
            If the field is structural, add it to PrivacyContractTests.allowedItemFieldKeys.
            """
        )
    }

    /// A fingerprint is not in the catalog, and needs the check more, not less.
    ///
    /// It is *persisted*: whatever it carries lands in `Lenses.json` and is read
    /// back on every launch for as long as the lens exists. And its job — knowing
    /// the same box after a redesign — is exactly the job a stored snippet of the
    /// region's text would do best.
    @Test("A region fingerprint declares only structural fields, nil or not")
    func fingerprintDeclaredFieldsAreStructuralOnly() throws {
        let fingerprint = try #require(LensSample.region.fingerprint)
        let declared = Set(Mirror(reflecting: fingerprint).children.compactMap(\.label))
        let unexpected = declared.subtracting(Self.allowedFingerprintKeys)

        #expect(
            unexpected.isEmpty,
            """
            RegionFingerprint declares field(s) \(unexpected.sorted()).
            A fingerprint is written to disk and re-read forever, so page text here is worse
            than page text in a catalog, not better. Attribute *names*, class tokens, counts
            and bands are enough to recognise a box.
            If the field is structural, add it to PrivacyContractTests.allowedFingerprintKeys.
            """
        )
    }

    /// The whole encoded fingerprint, keys at every depth.
    ///
    /// ``RegionRectBand`` could gain a `label` without either allow-list above
    /// noticing, the same way ``RegionRect`` could inside a catalog.
    @Test("A whole encoded fingerprint contains none of the page's words")
    func fingerprintCarriesNoProse() throws {
        let fingerprint = try #require(LensSample.region.fingerprint)
        let data = try ZenticCoding.makeEncoder().encode(fingerprint)
        let object = try #require(try JSONSerialization.jsonObject(with: data))
        let allowed = Self.allowedFingerprintKeys.union(["x", "y", "width", "height"])

        for key in Self.keys(in: object) where !allowed.contains(key) {
            let lowered = key.lowercased()
            for needle in Self.proseNeedles {
                #expect(!lowered.contains(needle), "a fingerprint gained key \"\(key)\"")
            }
        }

        // The values, not just the names. `attributeNames` is the field where the
        // distinction lives: `aria-label` is a name we keep and its value is prose
        // we do not, and nothing but this asserts which one is in there.
        let names = try #require(object as? [String: Any])["attributeNames"] as? [String]
        #expect(names == ["data-testid", "aria-label"])
    }

    @Test("A region catalog declares only structural fields, nil or not")
    func catalogDeclaredFieldsAreStructuralOnly() {
        let declared = Set(Mirror(reflecting: LensSample.catalog).children.compactMap(\.label))
        let unexpected = declared.subtracting(Self.allowedCatalogKeys)

        #expect(unexpected.isEmpty, "RegionCatalog declares field(s) \(unexpected.sorted())")
    }

    @Test("A skeleton node declares only structural fields, nil or not")
    func nodeDeclaredFieldsAreStructuralOnly() throws {
        let node = try #require(Sample.skeleton.nodes.first)
        let declared = Set(Mirror(reflecting: node).children.compactMap(\.label))
        // `SkeletonNode.id` encodes as `id`; the allow-list is keyed on the
        // encoded names, which agree with the declared ones here.
        let unexpected = declared.subtracting(Self.allowedNodeKeys)

        #expect(unexpected.isEmpty, "SkeletonNode declares field(s) \(unexpected.sorted())")
    }

    @Test("A region candidate encodes only structural fields")
    func candidateFieldsAreStructuralOnly() throws {
        let data = try ZenticCoding.makeEncoder().encode(LensSample.catalog)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let candidates = try #require(object["candidates"] as? [[String: Any]])

        for candidate in candidates {
            let unexpected = Set(candidate.keys).subtracting(Self.allowedCandidateKeys)
            #expect(
                unexpected.isEmpty,
                """
                RegionCandidate gained field(s) \(unexpected.sorted()).
                A catalog must never carry page text — see RegionCandidate's privacy contract.
                If the field is structural, add it to PrivacyContractTests.allowedCandidateKeys.
                """
            )
        }
    }

    @Test("A region catalog encodes only structural fields")
    func catalogFieldsAreStructuralOnly() throws {
        let data = try ZenticCoding.makeEncoder().encode(LensSample.catalog)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let unexpected = Set(object.keys).subtracting(Self.allowedCatalogKeys)

        #expect(unexpected.isEmpty, "RegionCatalog gained field(s) \(unexpected.sorted())")
    }

    @Test("A catalog measures its regions' text, never carries it")
    func catalogTextIsMeasured() throws {
        let data = try ZenticCoding.makeEncoder().encode(LensSample.catalog)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let candidates = try #require(object["candidates"] as? [[String: Any]])
        let first = try #require(candidates.first)

        #expect(first["textLength"] is NSNumber)
        #expect(!(first["textLength"] is String))
    }

    /// The catalog is what travels to a model, so it is checked whole rather
    /// than field by field.
    ///
    /// A nested type could add a text field without changing either allow-list
    /// above — `RegionRect` gaining a `label`, say. Encoding the whole thing and
    /// searching the bytes catches that, and catches a future field name none of
    /// us thought to forbid.
    @Test("A whole encoded catalog contains none of the page's words")
    func catalogCarriesNoProse() throws {
        let data = try ZenticCoding.makeEncoder().encode(
            ReaderEvent.lensRegions(LensSample.catalog)
        )
        let object = try #require(try JSONSerialization.jsonObject(with: data))

        for key in Self.keys(in: object) where !Self.allowedEncodedKeys.contains(key) {
            let lowered = key.lowercased()
            for needle in Self.proseNeedles {
                #expect(
                    !lowered.contains(needle),
                    """
                    An encoded RegionCatalog gained key "\(key)", which reads like page text.
                    Every key in the tree is checked, so a nested type — RegionRect gaining a
                    `label`, say — cannot slip past the two allow-lists above.
                    """
                )
            }
        }
    }

    /// Every key in a decoded JSON tree, at every depth.
    private static func keys(in value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            var found = Set(object.keys)
            for nested in object.values { found.formUnion(keys(in: nested)) }
            return found
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { $0.formUnion(keys(in: $1)) }
        }
        return []
    }
}
