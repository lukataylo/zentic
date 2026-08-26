import AppKit
import ZenticKit

/// Drives the "redesign this site" flow: prompt, generate, apply, remember.
///
/// Layer 2 already re-renders the page in Zentic's design system. This is the
/// axis on top of that — *which* design system. Presentation is separate from
/// tone on purpose: a tone change alters meaning and needs consent and a badge,
/// whereas a design change is lossless and reversible, so it needs no ceremony at
/// all and the user can play with it freely.
@MainActor
final class RedesignController {
    static let shared = RedesignController()

    let store = DesignStore()

    /// The user's standing override, when they have set one.
    ///
    /// A new defaults key rather than a migration of `zentic.designModel`. The old
    /// key meant "which model draws designs" and its default value, `onDevice`,
    /// now spells a *permanent* on-device pin — so carrying it forward would turn
    /// every existing install's inert default into a standing override that
    /// silently outranks routing forever. A preference nobody set should not be one.
    private static let preferenceDefaultsKey = "zentic.modelPreference"

    var modelPreference: ModelPreference {
        get {
            UserDefaults.standard.string(forKey: Self.preferenceDefaultsKey)
                .flatMap(ModelPreference.init(rawValue:)) ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.preferenceDefaultsKey) }
    }

    private let onDevice = FoundationModelsProvider()
    private let openAI = OpenAIProvider()

    /// Where one piece of work goes, and what to say if it cannot go anywhere.
    enum ModelResolution {
        case provider(any LLMProvider)
        /// See ``ModelOutcome/unavailable(reason:cloudRoute:)`` — same two fields,
        /// carried through so the UI still knows whether it has a button to offer.
        case unavailable(reason: String, cloudRoute: Bool)
    }

    /// Pick the provider for one piece of work.
    ///
    /// The app's single door to a model instance. ``ModelRouting`` owns the
    /// decision and is pure; this owns the two things it cannot be — which
    /// concrete providers exist, and what they report right now.
    func resolve(_ work: ModelWork) async -> ModelResolution {
        let route = ModelRouting.route(for: work, preference: modelPreference)
        // Both are asked, not just the primary: the fallback's answer is what
        // decides whether there is a route worth offering, and neither question
        // costs a network request — one reads a system flag, the other the Keychain.
        let outcome = ModelRouting.resolve(
            route,
            onDevice: await onDevice.availability(),
            cloud: await openAI.availability()
        )
        switch outcome {
        case .use(let tier):
            trace("model", "\(tier.rawValue) for \(work)")
            return .provider(tier == .onDevice ? onDevice : openAI)
        case .unavailable(let reason, let cloudRoute):
            trace("model", "no model for \(work): \(reason)")
            return .unavailable(reason: reason, cloudRoute: cloudRoute)
        }
    }

    /// Resolve, and when a key is the only thing missing, ask for it once.
    ///
    /// Only for the flows that opened a sheet of their own — the user is already
    /// standing over a modal they raised, so raising a second one is the shortest
    /// path to the thing they asked for. The rewrite path deliberately does not use
    /// this: it can start from a rail drag with no dialog on screen at all.
    private func resolveAskingForKey(
        _ work: ModelWork,
        over window: NSWindow?
    ) async -> (any LLMProvider)? {
        switch await resolve(work) {
        case .provider(let provider):
            return provider
        case .unavailable(let reason, let cloudRoute):
            guard cloudRoute else {
                present(error: reason, over: window)
                return nil
            }
            promptForAPIKey()
            guard case .provider(let provider) = await resolve(work) else {
                present(error: reason, over: window)
                return nil
            }
            return provider
        }
    }

    /// Ask for a prompt, generate, and hand back the theme.
    ///
    /// Returns nil when the user cancels or generation fails; the caller has
    /// already got a perfectly good page on screen either way.
    func promptForDesign(
        origin: String?,
        suggestions: [String] = [],
        over window: NSWindow?
    ) async -> ReaderTheme? {
        guard
            let prompt = await askForPrompt(
                origin: origin,
                suggestions: suggestions,
                over: window
            )
        else { return nil }

        // On-device by default, cloud only if the device model is out: a theme is
        // twenty token values from a closed schema, which is the shape of work the
        // small model handles, and it is generated once per site rather than once
        // per page. The key is asked for at the moment it is needed rather than
        // sending the user to a menu they have not found yet.
        guard let provider = await resolveAskingForKey(.theme, over: window) else { return nil }

        do {
            let tokens = try await provider.generateTheme(from: prompt)
            let theme = ReaderTheme(
                id: UUID().uuidString,
                name: prompt.count > 40 ? String(prompt.prefix(40)) + "…" : prompt,
                source: .generated,
                tokens: tokens,
                prompt: prompt,
                createdAt: Date()
            )
            await store.save(theme, for: origin)
            trace("redesign", "generated for \(origin ?? "all sites"): \(prompt)")
            return theme
        } catch {
            present(error: Self.message(for: error), over: window)
            return nil
        }
    }

    /// Ask for a look and have the model lay the whole page out in HTML.
    ///
    /// The heavier sibling of ``promptForDesign(origin:over:)``: that one changes
    /// the tokens our renderer draws with, this one hands the renderer's job to
    /// the model. Slower, costs a request per page rather than per site, and only
    /// the cloud provider does it — so it is a separate command rather than a
    /// checkbox someone trips over.
    func promptForDocument(
        extraction: ExtractionResult,
        origin: String?,
        over window: NSWindow?
    ) async -> GeneratedDocument? {
        guard
            let prompt = await askForPrompt(
                origin: origin,
                over: window,
                title: "Rebuild this page",
                explanation: """
                    Describe the look you want. The model lays this page out in \
                    HTML, using only the words already on it.

                    Code, tables, maths and embeds are never sent and are rendered \
                    by Zentic where the model places them. Scripts, frames, \
                    webfonts and remote images are stripped from what comes back, \
                    so a generated page cannot reach the network.

                    This one always uses OpenAI: laying out a whole document is \
                    past what the on-device model does well.
                    """
            )
        else { return nil }

        // ``ModelRouting`` sends this to the cloud with no fallback — the on-device
        // model declines it, and a fallback to a model that says no is just a
        // slower error. Asked through the router rather than hardcoded so the rule
        // lives in one place and a manual on-device pin is still honoured (and
        // still declined, in the provider's own words).
        guard let provider = await resolveAskingForKey(.document, over: window) else { return nil }

        do {
            let document = try await provider.generateDocument(
                DocumentRequest(extraction: extraction, prompt: prompt)
            )
            trace("redesign", "generated document for \(origin ?? "page"): \(prompt)")
            return document
        } catch {
            present(error: Self.message(for: error), over: window)
            return nil
        }
    }

    /// The saved design for an origin, if any.
    func savedDesign(for origin: String?) async -> ReaderTheme? {
        await store.design(for: origin)
    }

    /// Keep a built-in preset for this site.
    ///
    /// The same storage a generated design uses, deliberately: from the page's point
    /// of view a preset and a prompted design are both just validated tokens, and
    /// having two ways to remember "how this site should look" would mean two places
    /// to look when it looks wrong.
    func adopt(_ theme: ReaderTheme, for origin: String?) async {
        await store.save(theme, for: origin)
        trace("redesign", "\(theme.name) for \(origin ?? "all sites")")
    }

    func forget(origin: String?) async {
        await store.remove(origin: origin)
    }

    // MARK: - Key

    /// The BYO key sheet. Lives here rather than in the view controller because the
    /// redesign flow needs to raise it mid-flight, not only from the menu.
    func promptForAPIKey() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API key"
        alert.informativeText = """
            Used only for redesign and cloud rewriting, sent only to OpenAI, and \
            stored in your login Keychain. Zentic has no server: your key never \
            reaches us.
            """
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = APIKeyStore.redacted(.openAI) ?? "sk-…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            try? APIKeyStore.save(field.stringValue, for: .openAI)
        case .alertSecondButtonReturn:
            APIKeyStore.remove(.openAI)
        default:
            break
        }
    }

    // MARK: - Prompt

    private func askForPrompt(
        origin: String?,
        suggestions: [String] = [],
        over window: NSWindow?,
        title: String? = nil,
        explanation: String? = nil
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText =
            title ?? (origin.map { "Redesign \($0)" } ?? "Redesign every site")
        alert.informativeText = explanation ?? """
            Describe the look you want, or start from one of the suggestions and \
            edit it. The design is saved for this site and reused on every visit.

            The model returns typography, colour and spacing values — never CSS — \
            so a generated design cannot load a webfont, fetch an image, or reach \
            the network on your behalf.
            """
        alert.addButton(withTitle: "Redesign")
        alert.addButton(withTitle: "Cancel")

        // A combo box rather than a text field: it is still free text — anything can
        // be typed — but it opens with answers rather than with a blank. The
        // suggestions are tailored to the page, so the first one is usually close
        // enough to edit instead of compose.
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        field.completes = true
        field.hasVerticalScroller = suggestions.count > 6
        field.numberOfVisibleItems = 8
        field.addItems(withObjectValues: suggestions)
        field.placeholderString = suggestions.first ?? "minimal, generous whitespace, warm greys"

        // A design already saved for this site wins: editing what you have is the
        // common case once a site has been designed once.
        if let existing = (await store.design(for: origin))?.prompt, !existing.isEmpty {
            field.stringValue = existing
        }

        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }

        // `stringValue` is empty when a suggestion was picked from the list without
        // the field being edited, so fall back to the selection.
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = typed.isEmpty ? (field.objectValueOfSelectedItem as? String ?? "") : typed
        let prompt = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    private func present(error: String, over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Could not generate a design"
        alert.informativeText = error
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// One sentence for an `LLMError`, in the user's terms rather than the API's.
    /// Shared with ``LensController``: a model failure reads the same wherever it
    /// surfaces, and two copies of this would drift apart within a release.
    static func message(for error: any Error) -> String {
        guard let llm = error as? LLMError else { return "\(error)" }
        switch llm {
        case .notEntitled:
            return "Add an OpenAI API key first — Zentic ▸ OpenAI API Key… (⌘,)."
        case .providerFailed(_, let message):
            return message
        case .malformedOutput(let detail):
            return "The model returned something unusable: \(detail)"
        case .noProviderAvailable:
            return "No model is available."
        case .cancelled:
            return "Cancelled."
        case .contextTooLarge:
            return "That page is too large to process."
        }
    }
}

/// Menu copy for the routing override.
///
/// Here rather than in ``ModelPreference`` because the kit has no business owning
/// a menu title, and because the tooltip's job is to make Automatic look like the
/// answer rather than like the first of three equals.
extension ModelPreference {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .onDevice: "On-Device (Apple Intelligence)"
        case .cloud: "OpenAI"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return """
                Everyday rewrites run on your device; long rewrites, page layouts \
                and lenses go to OpenAI. Pages where wording matters never leave \
                your device.
                """
        case .onDevice:
            return "Nothing leaves your device. Page layouts and lenses will decline."
        case .cloud:
            return "Everything goes to OpenAI with your key, including short rewrites."
        }
    }
}
