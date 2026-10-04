import SwiftUI
import ZenticKit

/// The address bar's note that a page is not secure, and what that means.
///
/// Absent on an ordinary HTTPS page: the secure case is the normal one and
/// deserves no decoration. A plain `http:` page gets a small open lock; one
/// that asks for a password or card number gets the words "Not Secure" as
/// well; a page loaded over a certificate the user accepted anyway gets a
/// red one, for as long as that exception lasts.
struct ConnectionBadge: View {
    let tab: Tab
    @State private var explaining = false

    private enum Kind { case plainHTTP, httpForm, certificateException }

    private var state: Kind? {
        if tab.isOnCertificateException { return .certificateException }
        guard tab.url?.scheme == "http", tab.securityWarning == nil else { return nil }
        return tab.hasInsecureForm ? .httpForm : .plainHTTP
    }

    var body: some View {
        if let state {
            Button {
                explaining.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: state == .certificateException ? "lock.trianglebadge.exclamationmark.fill" : "lock.slash")
                        .font(.system(size: 10, weight: .semibold))
                    if state == .httpForm {
                        Text("Not Secure")
                            .font(.system(size: 10.5, weight: .semibold))
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                    }
                }
                .foregroundStyle(state == .plainHTTP ? Color.orange : Color.red)
                .padding(.horizontal, state == .httpForm ? 6 : 2)
                .frame(height: 18)
                .background {
                    if state == .httpForm { Capsule().fill(Color.red.opacity(0.12)) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state == .certificateException ? "Zentic couldn’t verify this site’s certificate" : "This connection is not secure")
            .accessibilityLabel(state == .certificateException ? "Certificate not verified" : "Not secure")
            .accessibilityHint("Explains why this connection is not secure")
            .popover(isPresented: $explaining, arrowEdge: .bottom) {
                ConnectionExplanation(tab: tab, state: state) { explaining = false }
            }
            .animation(.smooth(duration: 0.25), value: state)
        }
    }

    private struct ConnectionExplanation: View {
        let tab: Tab
        let state: Kind
        var dismiss: () -> Void

        var body: some View {
            let host = tab.displayHost
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: state == .certificateException ? "lock.trianglebadge.exclamationmark.fill" : "lock.slash.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(state == .plainHTTP ? Color.orange : Color.red)
                        .frame(width: 32, height: 32)
                        .background((state == .plainHTTP ? Color.orange : Color.red).opacity(0.14), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state == .certificateException ? "Certificate Not Verified" : "Not Secure")
                            .font(.headline)
                        Text(host).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }

                Text(explanation)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if state == .httpForm {
                    Label("This page asks for a password or card number. Don’t enter one here.", systemImage: "hand.raised.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Spacer()
                    if state == .certificateException {
                        Button("Show Certificate") {
                            dismiss()
                            if let trust = tab.serverTrust {
                                CertificateTrust.show(trust, for: host, in: tab.browser?.window)
                            }
                        }
                    } else if let secure = secureURL {
                        Button("Try HTTPS") {
                            dismiss()
                            tab.load(secure)
                        }
                        .help("Load this page over an encrypted connection, if the site offers one")
                    }
                }
            }
            .padding(16)
            .frame(width: 310)
        }

        private var explanation: String {
            switch state {
            case .plainHTTP, .httpForm:
                "Your connection to this site isn’t encrypted. Anyone on the same network — public Wi‑Fi, for example — can see what you do here, and change the page on its way to you."
            case .certificateException:
                "You chose to visit this site although Zentic couldn’t verify its certificate, so it can’t be sure who is on the other end. That choice lasts until you quit Zentic."
            }
        }

        private var secureURL: URL? {
            guard var components = tab.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
            components.scheme = "https"
            if components.port == 80 { components.port = nil }
            return components.url
        }
    }
}
