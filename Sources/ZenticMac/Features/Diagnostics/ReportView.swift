import AppKit
import SwiftUI
import ZenticKit

/// One report, in full, with the only ways it ever leaves the Mac: Copy,
/// Save… and Email to Developer…. What is shown is exactly what is sent.
struct ReportView: View {
    let report: ProblemReport
    /// A heading in place of the report's kind: after a crash, the sheet
    /// says what happened rather than what the report is called.
    var headline: String?
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var copied = false
    @State private var emailFailed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                ReportBadge(kind: report.kind, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline ?? report.kind.title)
                        .font(.title3.weight(.semibold))
                    Text(report.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(report.date.formatted(date: .complete, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            ReportText(text: report.text)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 0.5)
                }
                .padding(.horizontal, 20)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text("Stays on this Mac unless you copy, save or email it.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 10)

            HStack(spacing: 8) {
                Button("Delete", role: .destructive) {
                    Diagnostics.shared.delete(report)
                    dismiss()
                }
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    ReportActions.copy(report)
                    copied = true
                }
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(1.6))
                    copied = false
                }
                Button("Save…") { saving = true }
                Button("Email to Developer…") {
                    if !ReportActions.email(report) { emailFailed = true }
                }
                .help("Opens a new message to the developer with this report attached. Nothing is sent until you send it.")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 680, height: 560)
        .onExitCommand { dismiss() }
        .fileExporter(
            isPresented: $saving, item: report.text, contentTypes: [.plainText],
            defaultFilename: report.fileName
        ) { _ in }
        .alert("No Mail Account", isPresented: $emailFailed) {
            Button("Save…") { saving = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Zentic couldn’t start a new message. Save the report and attach it to an email to \(Diagnostics.developerEmail) yourself.")
        }
    }
}

/// The sheet "Send Report…" opens after a crash: the report about it, or a
/// moment's wait while it is written.
struct IncidentReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let incident = Diagnostics.shared.incident {
            ReportView(report: incident, headline: "Zentic Quit Unexpectedly")
        } else {
            VStack(spacing: 14) {
                ProgressView()
                Text("Preparing the report…").foregroundStyle(.secondary)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .frame(width: 680, height: 560)
        }
    }
}

/// The report itself: monospaced, selectable, and fast at any length — a
/// macOS crash log runs to thousands of lines.
private struct ReportText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.textContainerInset = NSSize(width: 10, height: 12)
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
        view.setAccessibilityLabel("Report")
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        if view.string != text {
            view.string = text
            view.scrollToBeginningOfDocument(nil)
        }
    }
}

/// A report's kind at a glance: a symbol on a softly tinted tile.
struct ReportBadge: View {
    let kind: ProblemReport.Kind
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(kind.tint.gradient.opacity(0.18))
            .overlay {
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(kind.tint.gradient)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension ProblemReport.Kind {
    var symbol: String {
        switch self {
        case .unexpectedQuit: "bolt.horizontal.circle"
        case .crash: "exclamationmark.octagon"
        case .hang: "hourglass"
        case .cpuUsage: "cpu"
        case .diskWrites: "internaldrive"
        }
    }

    var tint: Color {
        switch self {
        case .unexpectedQuit: .orange
        case .crash: .red
        case .hang: .yellow
        case .cpuUsage: .purple
        case .diskWrites: .blue
        }
    }
}

/// The ways a report leaves the Mac. Each is a deliberate user action.
@MainActor
enum ReportActions {
    static func copy(_ report: ProblemReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.text, forType: .string)
    }

    /// A draft in the user's mail app with the report attached. Returns
    /// false when there is no mail app to draft in.
    static func email(_ report: ProblemReport) -> Bool {
        guard let service = NSSharingService(named: .composeEmail) else { return false }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Zentic Reports", directoryHint: .isDirectory)
        let file = folder.appending(path: report.fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try report.text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        let body = "What were you doing when this happened? (Optional)\n\n\n— \(report.kind.title): \(report.summary)\n"
        let items: [Any] = [body, file]
        guard service.canPerform(withItems: items) else { return false }
        service.recipients = [Diagnostics.developerEmail]
        service.subject = "Zentic \(report.kind.title): \(report.summary)"
        service.perform(withItems: items)
        return true
    }
}
