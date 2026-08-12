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

    /// Which model draws the design.
    ///
    /// On-device is the default because it costs nothing and leaks nothing; OpenAI
    /// is there because a 3B model's taste has limits and a design prompt is one
    /// place where that shows. Nothing about the page is sent either way — a theme
    /// is generated from the user's own words, not from what they are reading.
    enum DesignModel: String, CaseIterable {
        case onDevice
        case openAI

        var title: String {
            switch self {
            case .onDevice: "On-Device (Apple Intelligence)"
            case .openAI: "OpenAI"
            }
        }
    }

    private static let modelDefaultsKey = "zentic.designModel"

    var designModel: DesignModel {
        get {
            UserDefaults.standard.string(forKey: Self.modelDefaultsKey)
                .flatMap(DesignModel.init(rawValue:)) ?? .onDevice
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.modelDefaultsKey) }
    }

    private let onDevice = FoundationModelsProvider()
    private let openAI = OpenAIProvider()

    private var provider: any LLMProvider {
        designModel == .onDevice ? onDevice : openAI
    }

    /// Ask for a prompt, generate, and hand back the theme.
    ///
    /// Returns nil when the user cancels or generation fails; the caller has
    /// already got a perfectly good page on screen either way.
    func promptForDesign(origin: String?, over window: NSWindow?) async -> ReaderTheme? {
        guard let prompt = await askForPrompt(origin: origin, over: window) else { return nil }

        // Ask for the key at the moment it is needed rather than sending the user
        // to a menu they have not found yet.
        if designModel == .openAI, !APIKeyStore.has(.openAI) {
            promptForAPIKey()
            guard APIKeyStore.has(.openAI) else { return nil }
        }

        switch await provider.availability() {
        case .available:
            break
        case .unavailable(let reason), .ineligible(let reason):
            present(error: reason, over: window)
            return nil
        }

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

        // Not `provider`: the on-device model declines this, so routing through
        // the user's model choice would just be a slower way to show an error.
        let provider = openAI

        if !APIKeyStore.has(.openAI) {
            promptForAPIKey()
            guard APIKeyStore.has(.openAI) else { return nil }
        }

        switch await provider.availability() {
        case .available:
            break
        case .unavailable(let reason), .ineligible(let reason):
            present(error: reason, over: window)
            return nil
        }

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
        over window: NSWindow?,
        title: String? = nil,
        explanation: String? = nil
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText =
            title ?? (origin.map { "Redesign \($0)" } ?? "Redesign every site")
        alert.informativeText = explanation ?? """
            Describe the look you want. The design is saved for this site and \
            reused on every visit.

            The model returns typography, colour and spacing values — never CSS — \
            so a generated design cannot load a webfont, fetch an image, or reach \
            the network on your behalf.
            """
        alert.addButton(withTitle: "Redesign")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "minimal, generous whitespace, warm greys"
        field.stringValue = (await store.design(for: origin))?.prompt ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        let prompt = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func message(for error: any Error) -> String {
        guard let llm = error as? LLMError else { return "\(error)" }
        switch llm {
        case .notEntitled:
            return "Add an OpenAI API key in Settings first."
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
