import AppKit

// M1: the Arc-style shell. One window, a sidebar of tabs, spaces, a ⌘K palette,
// and tab suspension so thirty tabs do not cost thirty web views.
//
// `main.swift` rather than `@main` because a SwiftPM executable has no nib and no
// bundle: the activation policy and the entire menu bar have to be installed
// programmatically before the run loop starts.

// Stamped before anything else runs, so the launch figure covers every line of
// our own startup. It cannot cover dyld and framework loading before `main` —
// `Launch.processStart` reads that from the kernel separately, because the number
// a user perceives is from double-click, not from `main`.
Launch.mainEntered = Date()

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
