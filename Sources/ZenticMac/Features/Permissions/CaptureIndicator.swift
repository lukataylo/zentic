import SwiftUI
import WebKit
import ZenticKit

/// The toolbar's camera and microphone light, shown while the page is using
/// either. Red for the camera and orange for the microphone, the colours
/// macOS uses in the menu bar; a muted device shows struck through.
/// Clicking it offers pause and stop.
struct CaptureIndicator: View {
    let permissions: TabPermissions
    @State private var showsControls = false

    var body: some View {
        Button {
            showsControls.toggle()
        } label: {
            CaptureGlyphs(permissions: permissions, size: 12.5)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .chromeGlass(in: Capsule())
        .help("This page is using your \(permissions.inUseDescription)")
        .accessibilityLabel("\(permissions.inUseTitle) in use")
        .accessibilityHint("Shows controls to pause or stop")
        .popover(isPresented: $showsControls, arrowEdge: .bottom) {
            CaptureControls(permissions: permissions) { showsControls = false }
        }
    }
}

/// The glyphs themselves, also shown on the folded toolbar's pill so a
/// scrolled page never hides that the camera is on.
struct CaptureGlyphs: View {
    let permissions: TabPermissions
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: size * 0.55) {
            if permissions.camera != .none {
                glyph(active: permissions.camera == .active, on: "video.fill", off: "video.slash.fill", tint: .red)
            }
            if permissions.microphone != .none {
                glyph(active: permissions.microphone == .active, on: "mic.fill", off: "mic.slash.fill", tint: .orange)
            }
        }
        .accessibilityHidden(true)
    }

    private func glyph(active: Bool, on: String, off: String, tint: Color) -> some View {
        Image(systemName: active ? on : off)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(active ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(.secondary))
            .contentTransition(.symbolEffect(.replace))
            // A slow breath while live: noticeable, never a distraction.
            .symbolEffect(.pulse, options: .repeating.speed(0.5), isActive: active && !reduceMotion)
    }
}

private struct CaptureControls: View {
    let permissions: TabPermissions
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if permissions.camera != .none {
                row(.camera, state: permissions.camera) { permissions.setCamera($0) }
            }
            if permissions.microphone != .none {
                row(.microphone, state: permissions.microphone) { permissions.setMicrophone($0) }
            }
            Divider()
            Button(role: .destructive) {
                permissions.stopCapture()
                dismiss()
            } label: {
                Label("Stop Sharing", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(.red)
        }
        .padding(14)
        .frame(width: 260)
    }

    private func row(_ permission: SitePermission, state: WKMediaCaptureState, set: @escaping (WKMediaCaptureState) -> Void)
        -> some View
    {
        let live = state == .active
        return HStack(spacing: 10) {
            PermissionTile(permission: permission, size: 26)
                .saturation(live ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(permission.title).font(.system(size: 13, weight: .semibold))
                Text(live ? "In use" : "Paused")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button(live ? "Pause" : "Resume") { set(live ? .muted : .active) }
                .buttonBorderShape(.capsule)
                .accessibilityLabel("\(live ? "Pause" : "Resume") \(permission.title.lowercased())")
        }
        .animation(.smooth(duration: 0.2), value: live)
    }
}

/// A tab row's note of what its page is doing: the capture light, or a hand
/// raised when it has a question waiting.
struct TabPermissionBadge: View {
    let permissions: TabPermissions

    var body: some View {
        if permissions.isCapturing {
            CaptureGlyphs(permissions: permissions, size: 9.5)
                .help("Using your \(permissions.inUseDescription)")
        } else if permissions.current != nil {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .help("This page is asking for permission")
                .accessibilityLabel("Asking for permission")
        }
    }
}

extension TabPermissions {
    /// "camera", "microphone" or "camera and microphone".
    var inUseDescription: String {
        switch (camera != .none, microphone != .none) {
        case (true, true): "camera and microphone"
        case (true, false): "camera"
        default: "microphone"
        }
    }

    /// The same, for a menu item: "Camera and Microphone".
    var inUseTitle: String {
        switch (camera != .none, microphone != .none) {
        case (true, true): "Camera and Microphone"
        case (true, false): "Camera"
        default: "Microphone"
        }
    }
}
