import SwiftUI
import ZenticKit

extension SitePermission {
    var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .popups: "Pop-up Windows"
        case .autoplay: "Auto-Play"
        case .downloads: "Downloads"
        }
    }

    /// For summaries, where space is short.
    var shortTitle: String {
        switch self {
        case .microphone: "Mic"
        case .popups: "Pop-ups"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .location: "location.fill"
        case .popups: "macwindow.on.rectangle"
        case .autoplay: "play.rectangle.fill"
        case .downloads: "arrow.down.circle.fill"
        }
    }

    /// The tile colour, chosen to match what the system uses for the same
    /// thing: red for the camera light, orange for the microphone dot.
    var tint: Color {
        switch self {
        case .camera: .red
        case .microphone: .orange
        case .location: .blue
        case .popups: .indigo
        case .autoplay: .pink
        case .downloads: .green
        }
    }

    /// One line for Settings: what deciding this actually changes.
    var explanation: String {
        switch self {
        case .camera: "Video calls, scanning and photo booths. A page can only ask while it is open."
        case .microphone: "Calls, dictation and voice notes."
        case .location: "Maps, weather and store finders ask where you are."
        case .popups: "A pop-up opened by a click always opens. This decides the ones a page opens on its own."
        case .autoplay: "Whether video and sound may start before you click. Takes effect when a page loads."
        case .downloads: "Whether a site may save files to your Downloads folder."
        }
    }

    /// What each decision is called for this permission. Pop-ups and
    /// auto-play are not questions a site asks, so their choices are named for
    /// what they do, as in Safari.
    func label(_ decision: PermissionDecision) -> String {
        switch (self, decision) {
        case (.popups, .ask): "Block and Notify"
        case (.popups, .deny): "Block"
        case (.autoplay, .allow): "Allow All Auto-Play"
        case (.autoplay, .ask): "Stop Media with Sound"
        case (.autoplay, .deny): "Never Auto-Play"
        case (_, .ask): "Ask"
        case (_, .allow): "Allow"
        case (_, .deny): "Deny"
        }
    }

    /// The order choices appear in a menu: autoplay reads from most to least
    /// permissive, the rest lead with the default.
    var choices: [PermissionDecision] {
        self == .autoplay ? [.allow, .ask, .deny] : [.ask, .allow, .deny]
    }
}

/// A permission's symbol on a small rounded tile of its colour — the same
/// tile in Settings, the page menu and the prompt, so each is recognisable.
struct PermissionTile: View {
    let permission: SitePermission
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(permission.tint.gradient)
            .overlay {
                Image(systemName: permission.symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
