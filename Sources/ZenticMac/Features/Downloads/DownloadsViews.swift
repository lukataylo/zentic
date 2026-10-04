import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ZenticKit

/// The toolbar's downloads button. Present only while something is
/// downloading or has downloaded this session, or while ⌥⌘L asks for the
/// list — it takes no room the rest of the time.
struct DownloadsButton: View {
    @Environment(Browser.self) private var browser
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let downloads = Downloads.shared

    private var windowScheme: ColorScheme {
        let appearance = browser.window?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    static func isShown(in browser: Browser) -> Bool {
        let downloads = Downloads.shared
        return downloads.presentedIn == browser.id || downloads.showsButton(private: browser.isPrivate)
    }

    var body: some View {
        let items = downloads.items(private: browser.isPrivate)
        let progress = DownloadProgress(items)
        let finished = items.count { $0.state == .finished }
        Button {
            downloads.presentedIn = downloads.presentedIn == browser.id ? nil : browser.id
        } label: {
            ZStack {
                if progress.isActive {
                    ProgressRing(fraction: progress.fraction, lineWidth: 2)
                        .frame(width: 24, height: 24)
                        .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: progress.isActive ? 11 : 13, weight: .semibold))
                    // Lands with a drop each time a file finishes.
                    .symbolEffect(.bounce.down.byLayer, options: .speed(reduceMotion ? 2 : 1), value: finished)
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .chromeGlass(in: Circle())
        .animation(.smooth(duration: 0.3), value: progress.isActive)
        .help("Downloads (⌥⌘L)")
        .accessibilityLabel("Downloads")
        .accessibilityValue(progress.accessibilityValue)
        .popover(
            isPresented: Binding(
                get: { downloads.presentedIn == browser.id },
                set: { if !$0, downloads.presentedIn == browser.id { downloads.presentedIn = nil } }),
            arrowEdge: .bottom
        ) {
            // The toolbar takes the page's light or dark; the popover is
            // drawn in the window's, and its text must match that instead.
            DownloadsList(isPrivate: browser.isPrivate)
                .environment(\.colorScheme, windowScheme)
        }
    }
}

/// A small ring beside the site's name on the folded toolbar, so a download
/// stays visible when the page has the whole card.
struct DownloadsPillRing: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        let progress = DownloadProgress(Downloads.shared.items(private: browser.isPrivate))
        if progress.isActive {
            ProgressRing(fraction: progress.fraction, lineWidth: 1.5)
                .frame(width: 11, height: 11)
                .accessibilityLabel("Downloading")
                .accessibilityValue(progress.accessibilityValue)
        }
    }
}

/// What is downloading in a window, summed up for the ring.
private struct DownloadProgress {
    var isActive: Bool
    /// Nil while no size is known.
    var fraction: Double?
    var count: Int

    @MainActor init(_ items: [Download]) {
        let active = items.filter { $0.state.isUnderway }
        isActive = !active.isEmpty
        count = active.count
        let sized = active.filter { $0.totalBytes > 0 }
        let total = sized.reduce(Int64(0)) { $0 + $1.totalBytes }
        fraction =
            sized.count == active.count && total > 0
            ? Double(sized.reduce(Int64(0)) { $0 + $1.completedBytes }) / Double(total) : nil
    }

    var accessibilityValue: String {
        guard isActive else { return "" }
        let files = count == 1 ? "1 file" : "\(count) files"
        guard let fraction else { return "Downloading \(files)" }
        return "Downloading \(files), \(fraction.formatted(.percent.precision(.fractionLength(0))))"
    }
}

/// A determinate ring, or — with no size known — a turning arc. Still with
/// Reduce Motion on.
struct ProgressRing: View {
    var fraction: Double?
    var lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(fraction ?? 0.28, 0.02))
                .stroke(Color.accentColor.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90 + (fraction == nil && turning ? 360 : 0)))
                .animation(.smooth(duration: 0.3), value: fraction)
        }
        .onAppear { startTurning() }
        .onChange(of: fraction == nil) { startTurning() }
    }

    private func startTurning() {
        guard fraction == nil, !reduceMotion else { return turning = false }
        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { turning = true }
    }
}

// MARK: - The list

/// The popover: every download for this kind of window, newest first.
struct DownloadsList: View {
    let isPrivate: Bool
    private let downloads = Downloads.shared

    var body: some View {
        let items = downloads.items(private: isPrivate)
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Downloads")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear") {
                    withAnimation(.smooth(duration: 0.25)) { downloads.clear(private: isPrivate) }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!items.contains { !$0.state.isUnderway && $0.state != .paused })
                .help("Remove finished, failed and cancelled downloads from the list. The files stay where they are.")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No Downloads")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(isPrivate ? "Files downloaded in private windows are listed here until you quit." : "Files you download appear here.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 30)
                .accessibilityElement(children: .combine)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            DownloadRow(item: item)
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(CGFloat(items.count) * DownloadRow.height + 8, 380))
            }
        }
        .frame(width: 380)
        .animation(.smooth(duration: 0.3), value: items.map(\.id))
    }
}

private struct DownloadRow: View {
    static let height: CGFloat = 58
    let item: Download
    @State private var hovering = false
    private let downloads = Downloads.shared

    var body: some View {
        HStack(spacing: 11) {
            FileIcon(name: item.name)
                .frame(width: 34, height: 34)
                .opacity(item.state == .finished && !item.isMissing ? 1 : 0.6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name.isEmpty ? "Starting…" : item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state.isUnderway || item.state == .paused {
                    Group {
                        if let fraction = item.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                        }
                    }
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(item.state == .paused ? .secondary : .accentColor)
                }
                Text(status)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(item.state.isFailed || item.isMissing ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) { actions }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture(count: 2) { downloads.open(item) }
        .onDrag {
            // Dragged out of the list, it is the file: into Finder, Mail, a
            // page's upload field.
            guard item.state == .finished, let file = item.file else { return NSItemProvider() }
            return NSItemProvider(contentsOf: file) ?? NSItemProvider()
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name.isEmpty ? "Download starting" : item.name)
        .accessibilityValue(status)
        .accessibilityAction(named: "Show in Finder") { downloads.reveal(item) }
    }

    @ViewBuilder
    private var actions: some View {
        switch item.state {
        case .active:
            RowButton(symbol: "pause.fill", help: "Pause") { downloads.pause(item) }
            RowButton(symbol: "xmark", help: "Cancel") { downloads.cancel(item) }
        case .pausing:
            RowButton(symbol: "xmark", help: "Cancel") { downloads.cancel(item) }
        case .paused:
            RowButton(symbol: "play.fill", help: "Resume") { downloads.resume(item) }
            RowButton(symbol: "xmark", help: "Cancel") { downloads.cancel(item) }
        case .failed where item.canResume, .cancelled where item.source != nil:
            RowButton(symbol: "arrow.clockwise", help: "Try Again") { downloads.resume(item) }
        case .finished:
            RowButton(symbol: "magnifyingglass", help: "Show in Finder") { downloads.reveal(item) }
                .disabled(item.isMissing)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var menu: some View {
        if item.state == .finished {
            Button("Open") { downloads.open(item) }
            Button("Show in Finder") { downloads.reveal(item) }
            Divider()
        }
        if let source = item.source {
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.absoluteString, forType: .string)
            }
        }
        if !item.state.isUnderway && item.state != .paused {
            Button("Remove from List") { downloads.remove(item) }
        }
    }

    private var status: String {
        if item.isMissing { return "Moved or deleted" }
        let done = item.completedBytes.formatted(.byteCount(style: .file))
        let total = item.totalBytes.formatted(.byteCount(style: .file))
        switch item.state {
        case .active:
            guard item.totalBytes > 0 else { return item.completedBytes > 0 ? done : "Waiting…" }
            return "\(done) of \(total)" + (timeLeft.map { " — \($0)" } ?? "")
        case .pausing: return "Pausing…"
        case .paused: return item.totalBytes > 0 ? "Paused — \(done) of \(total)" : "Paused"
        case .finished:
            return [total, item.source.map(URLGuess.displayHost)].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " — ")
        case .cancelled: return "Cancelled"
        case .failed(let message): return message
        }
    }

    private var timeLeft: String? {
        guard item.rate > 1, item.totalBytes > item.completedBytes else { return nil }
        let seconds = Double(item.totalBytes - item.completedBytes) / item.rate
        guard seconds.isFinite, seconds < 60 * 60 * 24 else { return nil }
        if seconds < 5 { return "a few seconds left" }
        let rounded = seconds < 60 ? seconds.rounded() : (seconds / 60).rounded() * 60
        return Duration.seconds(rounded)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1)) + " left"
    }
}

/// The Finder's icon for this kind of file — by its extension, so drawing a
/// row never touches the disk.
private struct FileIcon: View {
    let name: String

    var body: some View {
        let ext = (name as NSString).pathExtension
        let type = ext.isEmpty ? UTType.data : UTType(filenameExtension: ext) ?? .data
        Image(nsImage: NSWorkspace.shared.icon(for: type))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

private struct RowButton: View {
    let symbol: String
    let help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
