import SwiftUI

/// The private window's frame: a deep graphite shading into indigo, the same
/// in light and dark so a private window is recognisable at a glance — with
/// a faint sheen from the top-leading corner so it reads as glass, not paint.
struct PrivateWash: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.12, blue: 0.22), Color(red: 0.07, green: 0.07, blue: 0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .opacity(0.88)
            RadialGradient(
                colors: [Color(red: 0.42, green: 0.36, blue: 0.95).opacity(0.22), .clear],
                center: .topLeading, startRadius: 0, endRadius: 520)
        }
    }
}

/// What an empty private window shows: what private means here, plainly.
struct PrivateEmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "eye.slash")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color(red: 0.55, green: 0.5, blue: 1).gradient)
                .symbolEffect(.pulse, options: .nonRepeating)
            Text("Private Window")
                .font(.title2.weight(.semibold))
            Text("Pages you open here stay out of your history and your saved tabs, and their cookies and site data are forgotten when the window closes. Content blocking and site versions work as usual.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Text("⌘T to open a page")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
