import AppKit
import Observation
import WebKit
import ZenticKit

/// One question waiting for the user: a site wants something.
struct PermissionRequest: Identifiable {
    enum Kind: Equatable {
        /// Camera, microphone or both — WebKit asks for both at once.
        case capture([SitePermission])
        case location
        /// A pop-up the page tried to open by itself, held back.
        case popup(URL?, count: Int)
        case download(String)

        /// The permissions an answer is remembered for.
        var permissions: [SitePermission] {
            switch self {
            case .capture(let permissions): permissions
            case .location: [.location]
            case .popup: [.popups]
            case .download: [.downloads]
            }
        }
    }

    let id = UUID()
    var kind: Kind
    /// The page's site: what the decision is remembered for.
    let site: String
    /// The frame that asked, when it is another site embedded in the page.
    let embeddedHost: String?
    fileprivate var waiters: [(Bool) -> Void] = []
}

/// A tab's side of permissions: answering WebKit from the user's decisions,
/// queueing questions the user has to answer, and following the camera and
/// microphone while the page uses them.
@MainActor
@Observable
final class TabPermissions {
    /// Asked one at a time, oldest first.
    private(set) var queue: [PermissionRequest] = []
    var current: PermissionRequest? { queue.first }

    private(set) var camera: WKMediaCaptureState = .none
    private(set) var microphone: WKMediaCaptureState = .none
    var isCapturing: Bool { camera != .none || microphone != .none }

    @ObservationIgnored weak var tab: Tab?
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// When the current document began. Input before it was aimed at the
    /// page before: ⌘R, or Return on a link, is not the new page's gesture.
    @ObservationIgnored private var documentStart: TimeInterval = 0

    private var scope: PermissionScope { tab?.browser?.permissions ?? .shared }

    // MARK: - Web view lifetime

    /// Follow the capture state by KVO: WebKit announces every change, so
    /// nothing polls.
    func attach(_ webView: WKWebView) {
        LastInput.start()
        self.webView = webView
        observations = [
            webView.observe(\.cameraCaptureState, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.camera = wv.cameraCaptureState }
            },
            webView.observe(\.microphoneCaptureState, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.microphone = wv.microphoneCaptureState }
            },
        ]
    }

    /// The web view is going away: nothing it asked can be answered any more.
    func detach() {
        observations.removeAll()
        webView = nil
        camera = .none
        microphone = .none
        dismissAll()
    }

    /// A new document replaced the one whose questions are queued. A "yes"
    /// meant for the old page must never reach the new one.
    func documentChanged() {
        documentStart = ProcessInfo.processInfo.systemUptime
        dismissAll()
    }

    private func dismissAll() {
        let pending = queue
        queue = []
        for request in pending { request.waiters.forEach { $0(false) } }
    }

    // MARK: - Requests from WebKit

    func decideCapture(_ type: WKMediaCaptureType, origin: WKSecurityOrigin, frame: WKFrameInfo) async
        -> WKPermissionDecision
    {
        let permissions: [SitePermission] =
            switch type {
            case .camera: [.camera]
            case .microphone: [.microphone]
            default: [.camera, .microphone]
            }
        return await decide(.capture(permissions), origin: origin, frame: frame)
    }

    func decideLocation(origin: WKSecurityOrigin, frame: WKFrameInfo) async -> WKPermissionDecision {
        await decide(.location, origin: origin, frame: frame)
    }

    private func decide(_ kind: PermissionRequest.Kind, origin: WKSecurityOrigin, frame: WKFrameInfo) async
        -> WKPermissionDecision
    {
        guard let site = Self.site(origin) else { return .deny }
        let frameSite = Self.site(frame.securityOrigin)
        let embedded = frameSite == site ? nil : frame.securityOrigin.host
        return await ask(kind, site: site, embeddedHost: embedded) ? .grant : .deny
    }

    /// Whether a download may start. `site` is the page that started it, not
    /// the server the file comes from — that is usually a CDN nobody chose.
    func allowsDownload(named name: String, site: String?) async -> Bool {
        guard let site else { return scope.book.outcome(.downloads, for: nil) == .grant }
        return await ask(.download(name), site: site, embeddedHost: nil)
    }

    /// Whether a `window.open` may open, decided before WebKit needs an
    /// answer (it waits for none). A held-back pop-up becomes a notice that
    /// can still open it, in a tab of its own.
    func allowsPopup(to url: URL?, from page: URL?) -> Bool {
        let site = SiteKey.for(page)
        let userInitiated = LastInput.wasRecent(in: webView, since: documentStart)
        switch scope.book.outcome(.popups, for: site, userInitiated: userInitiated) {
        case .grant:
            // One click, one pop-up: a handler that opens a dozen gets one.
            if userInitiated { LastInput.consume() }
            return true
        case .deny: return false
        case .prompt:
            guard let site else { return false }
            if let index = queue.firstIndex(where: { if case .popup = $0.kind { $0.site == site } else { false } }),
                case .popup(_, let count) = queue[index].kind
            {
                // A page that fires five pop-ups gets one notice, not five.
                queue[index].kind = .popup(url, count: count + 1)
                return false
            }
            enqueue(PermissionRequest(kind: .popup(url, count: 1), site: site, embeddedHost: nil))
            return false
        }
    }

    private func ask(_ kind: PermissionRequest.Kind, site: String, embeddedHost: String?) async -> Bool {
        let book = scope.book
        let undecided = kind.permissions.filter { book.outcome($0, for: site) == .prompt }
        if kind.permissions.contains(where: { book.outcome($0, for: site) == .deny }) { return false }
        if undecided.isEmpty { return true }
        // Ask only about what is undecided: a site allowed the camera that
        // now wants the microphone too is asked about the microphone.
        let kind = if case .capture = kind { PermissionRequest.Kind.capture(undecided) } else { kind }
        return await withCheckedContinuation { continuation in
            // The same question again (a page retrying, or both of its frames
            // asking) waits on the one already on screen. Downloads join by
            // site whatever the file, so a page can't stack up a prompt per file.
            if let index = queue.firstIndex(where: { $0.kind.permissions == kind.permissions && $0.site == site }) {
                queue[index].waiters.append { continuation.resume(returning: $0) }
                return
            }
            var request = PermissionRequest(kind: kind, site: site, embeddedHost: embeddedHost)
            request.waiters = [{ continuation.resume(returning: $0) }]
            enqueue(request)
        }
    }

    private func enqueue(_ request: PermissionRequest) {
        queue.append(request)
        // The prompt hangs from the toolbar, so the toolbar has to be there.
        tab?.chromeCollapsed = false
    }

    // MARK: - The user's answer

    func answer(_ id: PermissionRequest.ID, allow: Bool, remember: Bool) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let request = queue.remove(at: index)
        if remember {
            // Only what was actually in question: a site already allowed the
            // camera keeps that when the user turns down its microphone.
            for permission in request.kind.permissions where scope.decision(permission, for: request.site) == .ask {
                scope.set(allow ? .allow : .deny, permission, for: request.site)
            }
        }
        if allow, case .popup(let url, _) = request.kind, let url, SiteKey.isWeb(url), let tab {
            tab.browser?.openTab(url, after: tab)
        }
        request.waiters.forEach { $0(allow) }
    }

    // MARK: - Capture controls

    func setCamera(_ state: WKMediaCaptureState) { webView?.setCameraCaptureState(state) }
    func setMicrophone(_ state: WKMediaCaptureState) { webView?.setMicrophoneCaptureState(state) }

    func stopCapture() {
        setCamera(.none)
        setMicrophone(.none)
    }

    // MARK: -

    private static func site(_ origin: WKSecurityOrigin) -> String? {
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        return SiteKey.for(components.url)
    }
}

/// The last click or key press in Zentic, and the view it went to — see
/// ``UserGesture``. Only input that went to the page counts: Return in the
/// address bar, or a click in another app, is not the page's user gesture,
/// and counting it would let a pop-up fired at load ride on the keystroke
/// that loaded the page. Clicks and key presses only: scrolling and moving
/// the pointer are not consent to anything.
@MainActor
private enum LastInput {
    private static var monitor: Any?
    // The clock is `systemUptime`, which is what `NSEvent.timestamp` counts.
    private static var time: TimeInterval = -.infinity
    private static weak var view: NSView?

    static func start() {
        guard monitor == nil else { return }
        // A local monitor sees each event once, before it is dispatched;
        // recording a time and a view costs nothing per key press.
        // Mouse down as well as up: some pages open on mousedown.
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .otherMouseUp, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            MainActor.assumeIsolated {
                // A menu shortcut is aimed at Zentic, not the page.
                if event.type == .keyDown, event.modifierFlags.contains(.command) { return }
                time = event.timestamp
                if event.type == .keyDown {
                    view = event.window?.firstResponder as? NSView
                } else {
                    // The window's frame view: its superview's coordinates,
                    // which `hitTest` wants, are the window's own.
                    view = event.window?.contentView?.superview?.hitTest(event.locationInWindow)
                }
            }
            return event
        }
    }

    static func wasRecent(in webView: WKWebView?, since documentStart: TimeInterval) -> Bool {
        guard let webView, let view, view.isDescendant(of: webView) else { return false }
        return UserGesture.counts(inputAt: time, now: ProcessInfo.processInfo.systemUptime, documentStart: documentStart)
    }

    /// A gesture opens one pop-up; the next needs another click.
    static func consume() { time = -.infinity }
}
