import Foundation
import Observation
import ZenticKit

/// The conversation that produces a site's custom version: an instruction, a
/// model call, a live preview, and the decision to keep it or not.
///
/// Nothing is stored until the user keeps it. A preview is applied to the live
/// page only, and discarding it puts the page back the way the user's saved
/// choice says.
@MainActor
@Observable
final class DesignSession {
    enum Phase: Equatable {
        case idle
        /// `note` says what the wait is for, when it is not the first answer.
        case working(started: Date, note: String?)
        case preview(CustomVersion)
        case failed(String)
    }

    var isPresented = false
    var draft = ""
    private(set) var phase: Phase = .idle
    /// Hide selectors the page refused (no match, or too broad).
    private(set) var rejected: [String] = []

    @ObservationIgnored private var task: Task<Void, Never>?

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    /// The version on screen and not yet kept. The tab is the source of
    /// truth: it is what the page actually shows.
    @ObservationIgnored weak var tab: Tab?
    var preview: CustomVersion? { tab?.previewing }

    func present() {
        isPresented = true
    }

    /// Close, abandoning any preview or call in flight.
    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        rejected = []
        draft = ""
        isPresented = false
    }

    func submit(on tab: Tab) {
        let instruction = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !isWorking, let url = tab.url else { return }
        // Refine what is on screen: the preview if there is one, else the kept version.
        let current = tab.previewing ?? tab.browser?.custom(for: url)
        let started = Date()
        phase = .working(started: started, note: nil)
        rejected = []

        task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            do {
                let designer = try AppModel.shared.designer()
                guard let outline = await tab.snapshot() else {
                    throw DesignError.malformed("This page isn't ready yet. Try again once it has loaded.")
                }
                let before = await tab.health()
                var request = OpenAIDesigner.Request(
                    url: url, title: tab.title, outline: outline, instruction: instruction, current: current,
                    screenshot: await tab.screenshot())
                let prompts = (current?.prompts ?? []) + [instruction]

                var version = try await self.answer(designer, request, prompts: prompts)
                self.rejected = await tab.preview(version)

                // Look at the result before offering it. A stylesheet that hid
                // the content or wrecked the layout gets one repair pass, with
                // a picture of what went wrong; if that fails too, the page is
                // put back and the user is told, never handed a broken site.
                if let problem = await Self.problem(before: before, tab: tab) {
                    trace("design", "repairing: \(problem)")
                    self.phase = .working(started: started, note: "Fixing a layout problem…")
                    request.current = version
                    request.problem = problem
                    request.screenshot = await tab.screenshot()
                    version = try await self.answer(designer, request, prompts: prompts)
                    self.rejected = await tab.preview(version)
                    if let still = await Self.problem(before: before, tab: tab) {
                        trace("design", "giving up: \(still)")
                        // Back to what was on screen before this attempt.
                        if let current, current != tab.browser?.custom(for: url) {
                            _ = await tab.preview(current)
                        } else {
                            tab.applyMode()
                        }
                        throw DesignError.malformed(
                            "That design broke the page (\(still)), so it wasn't applied. Try describing it differently.")
                    }
                }
                self.draft = ""
                self.phase = .preview(version)
            } catch is CancellationError {
                return
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func answer(
        _ designer: OpenAIDesigner, _ request: OpenAIDesigner.Request, prompts: [String]
    ) async throws -> CustomVersion {
        let answer = try await designer.design(request)
        try Task.checkCancellation()
        #if DEBUG
            trace("design", "base=\(answer.base.rawValue) hide=\(answer.hide)\n\(answer.css)")
        #endif
        return CustomVersion(
            base: answer.base, css: answer.css, hide: answer.hide, summary: answer.summary, prompts: prompts)
    }

    /// What is wrong with the page now, compared with before the preview.
    private static func problem(before: Tab.Health?, tab: Tab) async -> String? {
        // Let the new styles lay out before measuring.
        try? await Task.sleep(for: .milliseconds(400))
        guard let before, before.visibleText > 200, let after = await tab.health() else { return nil }
        let kept = Double(after.visibleText) / Double(before.visibleText)
        if kept < 0.35 {
            return "only \(Int(kept * 100))% of the page's text is still visible"
        }
        if after.overflowsX && !before.overflowsX {
            return "the page now scrolls sideways"
        }
        return nil
    }

    /// Stop waiting. Whatever was on screen before the request stays.
    func cancel(on tab: Tab) {
        task?.cancel()
        task = nil
        phase = tab.previewing.map(Phase.preview) ?? .idle
    }

    /// The page no longer shows the preview (navigation, a mode change).
    func previewDropped() {
        if case .preview = phase { phase = .idle }
    }

    /// Make the preview the site's version from now on.
    func keep(on tab: Tab) {
        guard let version = tab.previewing else { return }
        tab.browser?.saveCustom(version, for: tab.url)
        reset()
    }

    /// Throw the preview away and show the page as the saved choice says.
    func discard(on tab: Tab) {
        reset()
        tab.applyMode()
    }
}
