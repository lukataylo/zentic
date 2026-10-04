import SwiftUI
import ZenticKit

/// Settings › Security.
struct SafetySettings: View {
    @State private var safety = SafeBrowsing.shared
    @State private var certificates = CertificateTrust.shared

    var body: some View {
        @Bindable var safety = safety
        Form {
            Section {
                Toggle(isOn: $safety.isEnabled) {
                    Text("Warn before opening dangerous sites")
                    Text("Phishing and malware, checked against lists kept on this Mac. The addresses you open are never sent anywhere.")
                }

                if safety.isEnabled {
                    LabeledContent("Lists") {
                        HStack(spacing: 8) {
                            status
                            Button(safety.isUpdating ? "Updating…" : "Update Now") {
                                Task { await safety.update(force: true) }
                            }
                            .disabled(safety.isUpdating)
                        }
                    }
                }
            } header: {
                Text("Safe Browsing")
            } footer: {
                if safety.isEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pages from listed sites are stopped before they load, and other pages can’t pull scripts or downloads from them. Lists update once a day.")
                        // The phishing list's licence asks for attribution.
                        Text(ThreatFeed.all.map { "\($0.title): \($0.attribution)" }.joined(separator: "\n"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Exceptions") {
                    HStack(spacing: 8) {
                        Text(exceptionSummary).foregroundStyle(.secondary)
                        Button("Forget") {
                            safety.forgetBypasses()
                            certificates.forgetExceptions()
                        }
                        .disabled(safety.bypassed.isEmpty && certificates.exceptions.isEmpty)
                    }
                }
            } header: {
                Text("This Session")
            } footer: {
                Text("Sites you chose to visit despite a warning. Zentic forgets them when you quit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
        .animation(.smooth(duration: 0.25), value: safety.isEnabled)
    }

    @ViewBuilder
    private var status: some View {
        if let error = safety.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if safety.hostCount == 0 {
            Text(safety.isUpdating ? "Downloading…" : "Not downloaded yet").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(safety.hostCount.formatted()) sites")
                if let checked = safety.checkedAt {
                    Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var exceptionSummary: String {
        let count = safety.bypassed.count + certificates.exceptions.count
        return count == 0 ? "None" : "\(count) site\(count == 1 ? "" : "s")"
    }
}
