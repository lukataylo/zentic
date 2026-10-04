import SwiftUI
import ZenticKit

/// Where the toolbar's site control is, so a question about the site can
/// hang from it.
struct SiteControlAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// The selected tab's oldest unanswered question, hanging from the site
/// control with a little arrow pointing at it.
struct PermissionPromptLayer: View {
    let tab: Tab?
    let anchor: Anchor<CGRect>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let width: CGFloat = 344

    var body: some View {
        GeometryReader { proxy in
            if let tab, let request = tab.permissions.current, let anchor {
                let control = proxy[anchor]
                // Under the control, nudged so it never leaves the card.
                let x = min(max(control.midX - 30, 10), max(proxy.size.width - width - 10, 10))
                PermissionPrompt(
                    request: request, waiting: tab.permissions.queue.count - 1,
                    isPrivate: tab.browser?.isPrivate == true, arrowX: control.midX - x
                ) { allow, remember in
                    withAnimation(.smooth(duration: 0.28)) {
                        tab.permissions.answer(request.id, allow: allow, remember: remember)
                    }
                }
                .id(request.id)
                .frame(width: width)
                .offset(x: x, y: control.maxY + 4)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.9, anchor: UnitPoint(x: (control.midX - x) / width, y: 0))
                            .combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.78),
                   value: tab?.permissions.current?.id)
    }
}

private struct PermissionPrompt: View {
    let request: PermissionRequest
    /// How many more questions are queued behind this one.
    let waiting: Int
    let isPrivate: Bool
    let arrowX: CGFloat
    var answer: (_ allow: Bool, _ remember: Bool) -> Void

    @State private var remember: Bool
    /// The Allow button wakes a beat after the prompt appears, so a click
    /// aimed at the page cannot land on it — the oldest trick for getting a
    /// camera turned on.
    @State private var armed = false

    init(
        request: PermissionRequest, waiting: Int, isPrivate: Bool, arrowX: CGFloat,
        answer: @escaping (Bool, Bool) -> Void
    ) {
        self.request = request
        self.waiting = waiting
        self.isPrivate = isPrivate
        self.arrowX = arrowX
        self.answer = answer
        // Opening one pop-up is rarely a wish to open them all.
        if case .popup = request.kind { _remember = State(initialValue: false) } else { _remember = State(initialValue: true) }
    }

    var body: some View {
        let shape = PromptShape(arrowX: arrowX)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RequestTile(kind: request.kind)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.site)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(question)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .padding(.top, 1)
                    }
                    Toggle(isPrivate ? "Remember in this window" : "Remember for this site", isOn: $remember)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .padding(.top, 8)
                }
                Spacer(minLength: 0)
                if waiting > 0 {
                    Text("+\(waiting)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                        .help("\(waiting) more \(waiting == 1 ? "request" : "requests") from this page")
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(denyTitle) { answer(false, remember) }
                    .keyboardShortcut(.cancelAction)
                Button(allowTitle) { answer(true, remember) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!armed)
            }
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16 + PromptShape.arrowHeight)
        .padding(.bottom, 14)
        .panelGlass(in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.site) \(question)")
        .task {
            AccessibilityNotification.Announcement("\(request.site) \(question)").post()
            try? await Task.sleep(for: .milliseconds(500))
            armed = true
        }
    }

    private var question: String {
        switch request.kind {
        case .capture(let permissions) where permissions.count > 1: "wants to use your camera and microphone"
        case .capture(let permissions): "wants to use your \(permissions.first == .camera ? "camera" : "microphone")"
        case .location: "wants to know your location"
        case .popup(_, let count) where count > 1: "tried to open \(count) pop-up windows"
        case .popup: "tried to open a pop-up window"
        case .download(let name) where name.isEmpty: "wants to download a file"
        case .download(let name): "wants to download “\(name)”"
        }
    }

    private var detail: String? {
        if let host = request.embeddedHost { return "Asked by \(host), which this page embeds." }
        if case .popup(let url, _) = request.kind {
            guard let url, SiteKey.isWeb(url) else { return "A blank window, which can’t be opened on its own." }
            return url.host(percentEncoded: false).map { "To \($0)" }
        }
        return nil
    }

    private var allowTitle: String {
        if case .popup = request.kind { "Open" } else { "Allow" }
    }

    private var denyTitle: String {
        if case .popup = request.kind { "Keep Blocked" } else { "Don’t Allow" }
    }
}

/// The permission's tile; camera-and-microphone wears a microphone badge.
private struct RequestTile: View {
    let kind: PermissionRequest.Kind

    var body: some View {
        let permissions = kind.permissions
        PermissionTile(permission: permissions[0], size: 34)
            .overlay(alignment: .bottomTrailing) {
                if permissions.count > 1 {
                    PermissionTile(permission: permissions[1], size: 18)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18 * 0.28, style: .continuous)
                                .stroke(.background, lineWidth: 1.5)
                        }
                        .offset(x: 5, y: 5)
                }
            }
            .symbolEffect(.bounce, options: .nonRepeating)
    }
}

/// A rounded panel with a small arrow on its top edge.
struct PromptShape: Shape {
    static let arrowHeight: CGFloat = 7
    var arrowX: CGFloat
    var radius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + Self.arrowHeight, width: rect.width, height: rect.height - Self.arrowHeight)
        let panel = Path(roundedRect: body, cornerRadius: radius, style: .continuous)
        // Kept clear of the rounded corners.
        let x = min(max(arrowX, radius + 9), rect.width - radius - 9)
        var arrow = Path()
        arrow.move(to: CGPoint(x: x - 10, y: body.minY + 1))
        arrow.addQuadCurve(to: CGPoint(x: x, y: rect.minY), control: CGPoint(x: x - 3.5, y: body.minY))
        arrow.addQuadCurve(to: CGPoint(x: x + 10, y: body.minY + 1), control: CGPoint(x: x + 3.5, y: body.minY))
        arrow.closeSubpath()
        // One outline, so the glass rim runs up and over the arrow rather
        // than straight across its base.
        return panel.union(arrow)
    }
}
