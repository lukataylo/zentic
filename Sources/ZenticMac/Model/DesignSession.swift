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
        case working(started: Date)
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

    var preview: CustomVersion? {
        if case .preview(let version) = phase { return version }
        return nil
    }

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
        let current = preview ?? AppModel.shared.custom(for: url)
        let started = Date()
        phase = .working(started: started)
        rejected = []

        task = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            do {
                let designer = try AppModel.shared.designer()
                guard let outline = await tab.snapshot() else {
                    throw DesignError.malformed("This page isn't ready yet. Try again once it has loaded.")
                }
                let answer = try await designer.design(
                    .init(url: url, title: tab.title, outline: outline, instruction: instruction, current: current))
                try Task.checkCancellation()
                let version = CustomVersion(
                    base: answer.base, css: answer.css, hide: answer.hide, summary: answer.summary,
                    prompts: (current?.prompts ?? []) + [instruction])
                self.rejected = await tab.preview(version)
                self.draft = ""
                self.phase = .preview(version)
            } catch is CancellationError {
                return
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel(on tab: Tab) {
        task?.cancel()
        task = nil
        phase = .idle
        tab.applyMode()
    }

    /// Make the preview the site's version from now on.
    func keep(on tab: Tab) {
        guard let version = preview else { return }
        AppModel.shared.saveCustom(version, for: tab.url)
        reset()
    }

    /// Throw the preview away and show the page as the saved choice says.
    func discard(on tab: Tab) {
        reset()
        tab.applyMode()
    }
}
