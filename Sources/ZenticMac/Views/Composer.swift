import SwiftUI
import ZenticKit

/// Where the user describes their own version of a site.
///
/// Floats over the bottom of the page so the page stays visible: the preview
/// lands on the live page behind it, and the user decides to keep it with
/// the result in front of them.
struct Composer: View {
    @Environment(AppModel.self) private var app
    let tab: Tab
    @Bindable var design: DesignSession
    @FocusState private var focused: Bool

    private static let suggestions = [
        "Calm and minimal, lots of whitespace",
        "Dark mode with a warm accent",
        "Hide sidebars, ads and recommendations",
        "Bigger, more readable text",
        "Newspaper-style serif layout",
        "Just the main content",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !app.hasAPIKey {
                KeyEntry()
            } else {
                status
                input
            }
        }
        .padding(14)
        .frame(maxWidth: 640)
        .panelGlass(in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.18), radius: 30, x: 0, y: 10)
        .onAppear { focused = true }
        .onExitCommand { close() }
        .animation(.smooth(duration: 0.28), value: design.phase)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.purple.gradient)
            Text(hasVersion ? "Refine your \(tab.displayHost)" : "Your version of \(tab.displayHost)")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close (Esc)")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch design.phase {
        case .idle:
            if design.draft.isEmpty && !hasVersion {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Self.suggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                design.draft = suggestion
                                focused = true
                            }
                            .buttonStyle(SuggestionStyle())
                        }
                    }
                }
                .scrollClipDisabled()
            }
        case .working(let started):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(started))
                    Text(seconds < 4 ? "Reading the page…" : "Designing your version… \(seconds)s")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer()
                Button("Cancel") { design.cancel(on: tab) }
                    .controlSize(.small)
            }
            .padding(.vertical, 2)
        case .preview(let version):
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "eye")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(version.summary)
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !design.rejected.isEmpty {
                    Text("Skipped \(design.rejected.count) change\(design.rejected.count == 1 ? "" : "s") that would have hidden too much.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("Previewing — nothing is saved yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Discard") { design.discard(on: tab) }
                        .controlSize(.regular)
                    Button("Keep This Version") { design.keep(on: tab) }
                        .controlSize(.regular)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if message == DesignError.noKey.localizedDescription || message == DesignError.badKey.localizedDescription {
                    SettingsLink { Text("Settings…") }.controlSize(.small)
                }
            }
        }
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $design.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...5)
                .focused($focused)
                .disabled(design.isWorking)
                .onSubmit { design.submit(on: tab) }
                .padding(.vertical, 8)
                .padding(.leading, 12)

            Button {
                design.submit(on: tab)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(canSubmit ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.secondary.opacity(0.35))))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .padding(4)
            .help("Design (↩)")
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
    }

    private var hasVersion: Bool { design.preview != nil || app.custom(for: tab.url) != nil }

    private var placeholder: String {
        hasVersion ? "What should change?" : "Describe how you want \(tab.displayHost) to look…"
    }

    private var canSubmit: Bool {
        !design.isWorking && !design.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func close() {
        if design.preview != nil || design.isWorking {
            design.discard(on: tab)
        } else {
            design.reset()
        }
    }
}

private struct SuggestionStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.10 : 0.06)))
            .onHover { hovering = $0 }
    }
}

/// Paste a key without leaving the page.
struct KeyEntry: View {
    @Environment(AppModel.self) private var app
    @State private var key = ""
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom versions are designed by OpenAI with your own API key. It’s stored in your Keychain and only sent to OpenAI.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SecureField("sk-…", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button(checking ? "Checking…" : "Save Key", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            }
            if let error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
            }
            Link("Get a key from platform.openai.com", destination: URL(string: "https://platform.openai.com/api-keys")!)
                .font(.system(size: 11.5))
        }
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        checking = true
        error = nil
        Task {
            defer { checking = false }
            do {
                try await OpenAIDesigner(apiKey: trimmed, model: app.model).verify()
                try app.saveAPIKey(trimmed)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
