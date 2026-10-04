import SwiftUI
import ZenticKit

/// The page, on a rounded card, with Zentic's controls floating over it.
struct ContentCard: View {
    @Environment(Browser.self) private var browser
    @Environment(\.colorScheme) private var scheme
    /// Room for the traffic lights when no sidebar is there to hold them.
    var leadingClearance: CGFloat
    @State private var pointerNearTop = false

    private let radius: CGFloat = 12

    var body: some View {
        let tab = browser.selectedTab
        ZStack(alignment: .top) {
            Color(nsColor: .textBackgroundColor)

            WebContainer(tab: tab) { near in
                withAnimation(.smooth(duration: 0.3)) { pointerNearTop = near }
            }

            if let tab, let failure = tab.failure {
                LoadFailureView(failure: failure) { tab.reload() }
                    .transition(.opacity)
            } else if tab == nil {
                EmptyStateView()
            }

            FloatingToolbar(tab: tab, leadingClearance: leadingClearance, hoverReveal: pointerNearTop)

            if browser.findBar.isPresented, let tab {
                FindBar(tab: tab)
                    .padding(.top, Metrics.toolbarInset + 6)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let tab, tab.design.isPresented {
                Composer(tab: tab, design: tab.design)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 16)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            DownloadToast()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(14)

            if browser.commandBar.isPresented {
                CommandBar()
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.12), radius: 10, x: 0, y: 2)
        .animation(.smooth(duration: 0.3), value: browser.findBar.isPresented)
        .animation(.smooth(duration: 0.36), value: tab?.design.isPresented)
        .animation(.smooth(duration: 0.2), value: browser.commandBar.isPresented)
    }
}

/// A load that failed before anything committed, shown natively rather than
/// as WebKit's blank page.
private struct LoadFailureView: View {
    let failure: LoadFailure
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text("Zentic can’t open this page")
                .font(.title2.weight(.semibold))
            Text(failure.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let url = failure.url {
                Text(url.absoluteString)
                    .font(.callout.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var symbol: String {
        switch failure.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: "wifi.slash"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: "questionmark.circle"
        case NSURLErrorTimedOut: "clock.badge.exclamationmark"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
            NSURLErrorServerCertificateHasUnknownRoot:
            "lock.trianglebadge.exclamationmark"
        default: "exclamationmark.triangle"
        }
    }
}

private struct EmptyStateView: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Button("Open a Page…") {
                browser.commandBar.opensNewTab = true
                browser.commandBar.text = ""
                browser.commandBar.isPresented = true
            }
            .buttonStyle(.link)
            Text("⌘T").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DownloadToast: View {
    @State private var downloads = Downloads.shared

    var body: some View {
        if let item = downloads.latest {
            HStack(spacing: 10) {
                Image(systemName: item.failed != nil ? "exclamationmark.circle" : item.finished ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(item.failed != nil ? Color.red : item.finished ? Color.green : Color.accentColor)
                    .symbolEffect(.pulse, isActive: !item.finished && item.failed == nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    Text(item.failed ?? (item.finished ? "Downloaded" : "Downloading…"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if item.finished {
                    Button("Show in Finder") { downloads.reveal(item) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
                Button {
                    downloads.dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 360)
            .panelGlass(in: .rect(cornerRadius: 16))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
