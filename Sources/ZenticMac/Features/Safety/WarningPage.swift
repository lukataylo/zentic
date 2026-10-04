import SwiftUI

/// The full-card page shown in place of a site Zentic stopped: a listed
/// host, or a certificate it could not verify.
///
/// Loud on purpose — a warning that looks like the rest of the browser gets
/// clicked through — but calm in its words: what happened, what it means for
/// you, one obvious way out. The way past it sits behind "Show Details",
/// below the facts it should be weighed against.
struct WarningPage<Details: View>: View {
    enum Tone {
        /// A listed phishing or malware host.
        case danger
        /// A certificate problem: often a misconfiguration, sometimes an attack.
        case caution

        var colors: [Color] {
            switch self {
            case .danger: [Color(red: 0.80, green: 0.17, blue: 0.15), Color(red: 0.42, green: 0.04, blue: 0.10)]
            case .caution: [Color(red: 0.88, green: 0.46, blue: 0.10), Color(red: 0.50, green: 0.17, blue: 0.06)]
            }
        }

        /// Text on the white primary button.
        var ink: Color {
            switch self {
            case .danger: Color(red: 0.62, green: 0.08, blue: 0.10)
            case .caution: Color(red: 0.62, green: 0.26, blue: 0.04)
            }
        }
    }

    let tone: Tone
    let symbol: String
    let title: String
    let host: String
    let message: String
    var footnote: String?
    var secondary: WarningAction?
    /// Nil when there is no way past this one (a revoked certificate).
    var bypass: WarningAction?
    var goBack: () -> Void
    @ViewBuilder var details: Details

    @State private var showsDetails = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            background
            GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    emblem
                        .padding(.bottom, 22)
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 12)
                    Text(host)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                        .textSelection(.enabled)
                        .accessibilityLabel("Address: \(host)")
                        .padding(.bottom, 20)
                    Text(message)
                        .font(.system(size: 15.5))
                        .lineSpacing(3.5)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    if let footnote {
                        Text(footnote)
                            .font(.system(size: 13))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }
                    actions
                        .padding(.top, 30)
                    if showsDetails {
                        detailsPanel
                            .padding(.top, 22)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: 520)
                .padding(.horizontal, 40)
                .padding(.top, Metrics.toolbarInset + 32)
                .padding(.bottom, 56)
                // Centred in the card while it fits, a little above the
                // middle as a page's optical centre is; scrolls when it doesn't.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height * 0.92)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 10)
            }
            .scrollBounceBehavior(.basedOnSize)
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.45, extraBounce: 0.05)) {
                appeared = true
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: tone.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            // A soft light behind the emblem, so the page has a centre rather
            // than being a flat wall of colour.
            RadialGradient(
                colors: [.white.opacity(0.20), .clear], center: UnitPoint(x: 0.5, y: 0.22),
                startRadius: 0, endRadius: 420)
            // And a little weight at the bottom edge.
            LinearGradient(colors: [.clear, .black.opacity(0.22)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var emblem: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.13))
                .overlay(Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .symbolEffect(.bounce.up, options: .nonRepeating, value: appeared && !reduceMotion)
        }
        .frame(width: 96, height: 96)
        .accessibilityHidden(true)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38, extraBounce: 0.04)) {
                    showsDetails.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Text(showsDetails ? "Hide Details" : "Show Details")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(showsDetails ? 180 : 0))
                }
            }
            .buttonStyle(WarningButtonStyle(kind: .quiet, ink: tone.ink))
            .accessibilityHint("Shows what Zentic found, and the option to continue")

            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .buttonStyle(WarningButtonStyle(kind: .secondary, ink: tone.ink))
            }
            Button("Go Back", action: goBack)
                .buttonStyle(WarningButtonStyle(kind: .primary, ink: tone.ink))
                // No Return shortcut: the command bar and find bar float over
                // this page, and Return in their fields would press it.
        }
    }

    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            details
            if let bypass {
                Divider().overlay(.white.opacity(0.2))
                VStack(alignment: .leading, spacing: 6) {
                    Button(action: bypass.action) {
                        Label(bypass.title, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.92))
                    .accessibilityHint(bypass.note)
                    Text(bypass.note)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
    }
}

struct WarningAction {
    var title: String
    /// What choosing it means, said under the button.
    var note = ""
    var action: () -> Void
}

/// One fact in the details panel: a small caption over its value.
struct WarningFact: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.4)
                .foregroundStyle(.white.opacity(0.58))
            Text(value)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The page's buttons: white, glassy, or nearly not there.
private struct WarningButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    let kind: Kind
    let ink: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: kind == .quiet ? .medium : .semibold))
            .foregroundStyle(kind == .primary ? ink : .white.opacity(kind == .quiet ? 0.85 : 1))
            .padding(.horizontal, kind == .quiet ? 6 : 18)
            .frame(height: 34)
            .background {
                switch kind {
                case .primary:
                    Capsule().fill(.white).shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                case .secondary:
                    Capsule().fill(.white.opacity(configuration.isPressed ? 0.24 : 0.15))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                case .quiet:
                    Capsule().fill(.white.opacity(configuration.isPressed ? 0.12 : 0))
                }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}
