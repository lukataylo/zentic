import SwiftUI
import ZenticKit

/// Settings › Diagnostics: every problem report on this Mac, to read, keep,
/// send or delete.
struct DiagnosticsSettings: View {
    private var diagnostics: Diagnostics { .shared }
    @State private var selection: ProblemReport.ID?
    @State private var shown: ProblemReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor.gradient)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Problem Reports").font(.headline)
                    Text("When Zentic crashes, hangs or works your Mac too hard, the report appears here the next time it opens. Reports stay on this Mac; nothing is sent unless you send it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Group {
                if let reports = diagnostics.reports {
                    if reports.isEmpty {
                        ContentUnavailableView {
                            Label("No Problems Reported", systemImage: "checkmark.seal")
                                .symbolRenderingMode(.hierarchical)
                        } description: {
                            Text("Zentic hasn’t crashed or hung. If it does, you’ll find out what happened here.")
                        }
                    } else {
                        list(reports)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 300)
            .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5)
            }
            .padding(.horizontal, 20)

            HStack {
                Button("Show Report…") { shown = selected }
                    .disabled(selected == nil)
                Button("Delete") { if let selected { delete(selected) } }
                    .disabled(selected == nil)
                Spacer()
                Text("Kept for \(Int(ProblemReportStore.maxAge / 86_400)) days, up to \(ProblemReportStore.maxReports).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onAppear { diagnostics.loadIfNeeded() }
        .sheet(item: $shown) { ReportView(report: $0) }
    }

    private var selected: ProblemReport? {
        diagnostics.reports?.first { $0.id == selection }
    }

    private func list(_ reports: [ProblemReport]) -> some View {
        List(selection: $selection) {
            ForEach(reports) { report in
                ReportRow(report: report).tag(report.id)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: ProblemReport.ID.self) { ids in
            if let report = reports.first(where: { ids.contains($0.id) }) {
                Button("Show Report…") { shown = report }
                Button("Copy") { ReportActions.copy(report) }
                Button("Email to Developer…") { _ = ReportActions.email(report) }
                Divider()
                Button("Delete", role: .destructive) { delete(report) }
            }
        } primaryAction: { ids in
            // Double-click or Return opens it, as in Finder.
            shown = reports.first { ids.contains($0.id) }
        }
        .onDeleteCommand { if let selected { delete(selected) } }
        .animation(.snappy(duration: 0.25), value: reports.map(\.id))
    }

    private func delete(_ report: ProblemReport) {
        if selection == report.id { selection = nil }
        diagnostics.delete(report)
    }
}

private struct ReportRow: View {
    let report: ProblemReport

    var body: some View {
        HStack(spacing: 11) {
            ReportBadge(kind: report.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(report.kind.title).font(.body.weight(.medium))
                Text(report.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(report.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
