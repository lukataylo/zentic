import ContentBlockerConverter
import Foundation

/// Which half of a converted filter list an entry belongs to.
///
/// The split exists so ``ShieldState/blockingOnly`` can mean something. WebKit
/// evaluates each `WKContentRuleList` independently, so an `ignore-previous-rules`
/// entry in one list cannot cancel a rule in another — which rules out the obvious
/// design of "one small allowlist list layered over the big ones". The only lever
/// left is *which lists are attached* to a tab, so cosmetic rules have to be
/// compiled separately from network rules to be detachable on their own.
public enum RuleClass: String, Sendable, Codable, CaseIterable {
    /// `block` and `block-cookies`: stops the request reaching the network.
    case network
    /// `css-display-none`: hides an element that loaded from first-party markup.
    case cosmetic
}

/// One compiled-list-worth of Safari content-blocking JSON.
public struct RuleListChunk: Sendable, Hashable {
    public var ruleClass: RuleClass
    /// Index within its class, for a stable identifier.
    public var index: Int
    public var entryCount: Int
    public var json: String
}

public struct ConvertedFilterList: Sendable, Hashable {
    public var listID: String
    /// One `WKContentRuleList` per chunk.
    public var chunks: [RuleListChunk]
    /// Rules read from the list text, comments and blank lines excluded.
    public var sourceRuleCount: Int
    /// Distinct Safari rules the converter produced, counted before splitting
    /// duplicated any of them across chunks.
    public var safariRuleCount: Int
    /// Source rules that Safari's syntax cannot express — unparseable lines,
    /// scriptlets, extended CSS, `$csp`, `$redirect` and friends — plus anything
    /// the converter truncated at its own entry ceiling.
    public var droppedRuleCount: Int
}

/// Drives SafariConverterLib and splits its output into compilable chunks.
public enum RuleConverter {
    private static let exceptionAction = "ignore-previous-rules"
    private static let cosmeticAction = "css-display-none"

    /// Converts Adblock-Plus-syntax rules to Safari content-blocking JSON, split
    /// by ``RuleClass`` and then by `entriesPerList`.
    ///
    /// - Parameter entriesPerList: Entries allowed in one chunk. Defaults to the
    ///   OS ceiling; tests lower it to exercise splitting.
    public static func convert(
        rules: [String],
        listID: String,
        entriesPerList: Int = BlockerLimits.entriesPerRuleList
    ) throws -> ConvertedFilterList {
        precondition(entriesPerList > 0)

        let result = ContentBlockerConverter().convertArray(
            rules: rules,
            safariVersion: SafariVersion.autodetect(),
            advancedBlocking: false
        )

        // Three ways a rule fails to reach Safari, and the library reports them in
        // three different currencies.
        //
        // `sourceRulesCount` counts what parsed; `sourceSafariCompatibleRulesCount`
        // counts what parsed *and* had a Safari shape, so the gap from the input count
        // covers both unparseable lines and scriptlet/extended-CSS rules. `errorsCount`
        // covers both parse failures and rules that parsed but then failed to compile
        // — an uncompilable regex, say — so the parse failures have to be subtracted
        // back out or they count twice.
        let parseFailures = max(0, rules.count - result.sourceRulesCount)
        let inexpressible = max(0, rules.count - result.sourceSafariCompatibleRulesCount)
        let compileFailures = max(0, result.errorsCount - parseFailures)
        let dropped = inexpressible + compileFailures + result.discardedSafariRules

        guard result.safariRulesCount > 0 else {
            // An empty result is a real outcome — a list of nothing but scriptlets
            // converts to nothing. The converter substitutes a placeholder rule in
            // that case, which would be pointless to compile.
            return ConvertedFilterList(
                listID: listID,
                chunks: [],
                sourceRuleCount: rules.count,
                safariRuleCount: 0,
                droppedRuleCount: dropped
            )
        }

        let entries = canonicalise(try decode(result.safariRulesJSON, listID: listID))

        var chunks: [RuleListChunk] = []
        for ruleClass in RuleClass.allCases {
            chunks += try split(
                entries.filter { belongs($0, to: ruleClass) },
                ruleClass: ruleClass,
                listID: listID,
                entriesPerList: entriesPerList
            )
        }

        return ConvertedFilterList(
            listID: listID,
            chunks: chunks,
            sourceRuleCount: rules.count,
            safariRuleCount: result.safariRulesCount,
            droppedRuleCount: dropped
        )
    }

    // MARK: - Canonical order

    /// Makes the converter's output reproducible for identical input.
    ///
    /// SafariConverterLib groups rules through dictionaries and Swift seeds its hashing
    /// per process, so two runs over the same list emit the same entries in a different
    /// order. Since a compiled list is identified by the hash of its JSON, that would
    /// mean every rebuild minted fresh identifiers and WebKit could never recognise
    /// work it had already done.
    ///
    /// Reordering is safe *only* within a run of entries that share an action. The
    /// ordering that carries meaning is between different actions:
    /// `ignore-previous-rules` cancels what precedes it, and `$important` blocks are
    /// deliberately emitted after ordinary exceptions so that they win. Within one
    /// action the verdict is order-independent — any matching `block` blocks, every
    /// matching `css-display-none` applies — so each run is sorted by a canonical key.
    /// Set-valued trigger fields are sorted for the same reason.
    private static func canonicalise(_ entries: [BlockerEntry]) -> [BlockerEntry] {
        let sortedFields = entries.map { entry -> BlockerEntry in
            var entry = entry
            if let selector = entry.action.selector {
                entry = BlockerEntry(
                    trigger: entry.trigger,
                    action: BlockerEntry.Action(
                        type: entry.action.type,
                        selector: canonicalSelector(selector)
                    )
                )
            }
            entry.trigger.ifDomain = entry.trigger.ifDomain?.sorted()
            entry.trigger.unlessDomain = entry.trigger.unlessDomain?.sorted()
            entry.trigger.ifFrameUrl = entry.trigger.ifFrameUrl?.sorted()
            entry.trigger.unlessFrameUrl = entry.trigger.unlessFrameUrl?.sorted()
            entry.trigger.resourceType = entry.trigger.resourceType?.sorted()
            entry.trigger.loadType = entry.trigger.loadType?.sorted()
            entry.trigger.loadContext = entry.trigger.loadContext?.sorted()
            return entry
        }

        var result: [BlockerEntry] = []
        result.reserveCapacity(sortedFields.count)
        var start = sortedFields.startIndex
        while start < sortedFields.endIndex {
            var end = sortedFields.index(after: start)
            while end < sortedFields.endIndex,
                sortedFields[end].action.type == sortedFields[start].action.type
            {
                end = sortedFields.index(after: end)
            }
            result += sortedFields[start..<end]
                .map { (sortKey($0), $0) }
                .sorted { $0.0 < $1.0 }
                .map(\.1)
            start = end
        }
        return result
    }

    /// Sorts a selector list, which the converter builds by merging every generic
    /// cosmetic rule in the list into one comma-separated selector — from a set, so in
    /// an arbitrary order.
    ///
    /// Only commas outside brackets, parentheses and quotes separate selectors:
    /// `[data-x="a,b"]` and `:not(a, b)` are single selectors. As a second guard the
    /// rewrite is only used when it rejoins to exactly the input, so an unfamiliar
    /// spelling is left alone rather than mangled.
    static func canonicalSelector(_ selector: String) -> String {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?

        for character in selector {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case "(", "[":
                depth += 1
                current.append(character)
            case ")", "]":
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)

        guard parts.count > 1, quote == nil, depth == 0 else { return selector }
        let trimmed = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !trimmed.contains(where: \.isEmpty),
            trimmed.joined(separator: ", ") == selector
        else { return selector }
        return trimmed.sorted().joined(separator: ", ")
    }

    private static func sortKey(_ entry: BlockerEntry) -> String {
        let trigger = entry.trigger
        return [
            trigger.urlFilter ?? "",
            entry.action.selector ?? "",
            (trigger.ifDomain ?? []).joined(separator: ","),
            (trigger.unlessDomain ?? []).joined(separator: ","),
            (trigger.resourceType ?? []).joined(separator: ","),
            (trigger.loadType ?? []).joined(separator: ","),
            (trigger.loadContext ?? []).joined(separator: ","),
            (trigger.ifFrameUrl ?? []).joined(separator: ","),
            (trigger.unlessFrameUrl ?? []).joined(separator: ","),
            trigger.requestMethod ?? "",
            trigger.caseSensitive.map(String.init) ?? "",
        ].joined(separator: "\u{1}")
    }

    // MARK: - Classification

    /// Exceptions belong to *both* classes.
    ///
    /// That is not a shortcut, it is what the original ordering already does: the
    /// converter emits `ignore-previous-rules` entries after the `css-display-none`
    /// entries as well as after the blocking ones, so an unqualified `@@||site^`
    /// already unhides on that site. Copying them into both classes preserves that
    /// behaviour instead of quietly changing it.
    private static func belongs(_ entry: BlockerEntry, to ruleClass: RuleClass) -> Bool {
        switch entry.action.type {
        case exceptionAction: true
        case cosmeticAction: ruleClass == .cosmetic
        // Unknown actions land in `.network`, the class that stays attached at
        // every shield level except `.off`, so a converter update that adds an
        // action type fails towards blocking rather than silently towards not.
        default: ruleClass == .network
        }
    }

    // MARK: - Splitting

    /// Splits one class's entries into chunks of at most `entriesPerList`.
    ///
    /// Every chunk gets a copy of *all* the exceptions, because a chunk that keeps
    /// a block rule but loses the `@@` rule that excepts it over-blocks, and
    /// over-blocking is how a blocker breaks a checkout page. With exceptions
    /// present everywhere, each chunk is an order-preserving subsequence of the
    /// original that can only ever under-block; since WebKit blocks a request when
    /// *any* attached list blocks it, the union of the chunks reproduces the
    /// original verdict.
    ///
    /// The only ceiling applied here is the entry count. iOS additionally has trouble
    /// compiling very large JSON regardless of entry count (SafariConverterLib issue
    /// #56, FB13282146), which will need a byte ceiling alongside this one at M6. It is
    /// left out rather than guessed at: an unvalidated threshold that splits EasyPrivacy
    /// into needless extra lists would be worse than a named gap.
    private static func split(
        _ entries: [BlockerEntry],
        ruleClass: RuleClass,
        listID: String,
        entriesPerList: Int
    ) throws -> [RuleListChunk] {
        let exceptions = entries.indices.filter { entries[$0].action.type == exceptionAction }
        let decisive = entries.indices.filter { entries[$0].action.type != exceptionAction }
        // Exceptions alone would compile to a list that does nothing.
        guard !decisive.isEmpty else { return [] }

        let capacity = entriesPerList - exceptions.count
        guard capacity > 0 else {
            // Genuinely unrecoverable: the exceptions alone exceed what one
            // compiled list can hold, so no split keeps them all present.
            throw BlockerError.ruleLimitExceeded(list: listID, count: entries.count)
        }

        var chunks: [RuleListChunk] = []
        var start = decisive.startIndex
        while start < decisive.endIndex {
            let end = min(start + capacity, decisive.endIndex)
            let merged = mergeByIndex(decisive[start..<end], exceptions)
            chunks.append(
                RuleListChunk(
                    ruleClass: ruleClass,
                    index: chunks.count,
                    entryCount: merged.count,
                    json: try encode(merged.map { entries[$0] }, listID: listID)
                )
            )
            start = end
        }
        return chunks
    }

    /// Interleaves two ascending index runs, so the chunk keeps the converter's
    /// ordering. Order is load-bearing: `$important` block rules are emitted after
    /// ordinary exceptions precisely so they win, and re-sorting would invert that.
    private static func mergeByIndex(
        _ lhs: ArraySlice<Int>,
        _ rhs: [Int]
    ) -> [Int] {
        var merged: [Int] = []
        merged.reserveCapacity(lhs.count + rhs.count)
        var i = lhs.startIndex
        var j = rhs.startIndex
        while i < lhs.endIndex && j < rhs.endIndex {
            if lhs[i] < rhs[j] {
                merged.append(lhs[i])
                i += 1
            } else {
                merged.append(rhs[j])
                j += 1
            }
        }
        merged.append(contentsOf: lhs[i...])
        merged.append(contentsOf: rhs[j...])
        return merged
    }

    // MARK: - JSON

    private static func decode(_ json: String, listID: String) throws -> [BlockerEntry] {
        do {
            return try JSONDecoder().decode([BlockerEntry].self, from: Data(json.utf8))
        } catch {
            throw BlockerError.compilationFailed(
                list: listID,
                message: "converter emitted JSON we cannot read back: \(error)"
            )
        }
    }

    private static func encode(_ entries: [BlockerEntry], listID: String) throws -> String {
        let encoder = JSONEncoder()
        // Sorted keys because Foundation's encoder does not otherwise promise a key
        // order — it varies between entries in a single run. Since the identifier of a
        // compiled list is a hash of these bytes, an unstable key order alone would be
        // enough to defeat the cache.
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        do {
            return String(decoding: try encoder.encode(entries), as: UTF8.self)
        } catch {
            throw BlockerError.compilationFailed(
                list: listID,
                message: "could not re-encode converted rules: \(error)"
            )
        }
    }
}
