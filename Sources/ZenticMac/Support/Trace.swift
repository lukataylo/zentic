import Foundation

/// Print a diagnostic line to stdout.
///
/// `OSLog` output from a SwiftPM executable is not reliably retrievable — there is
/// no bundle identifier for `log show` to filter on — and bridge traffic is the
/// single most useful thing to watch while developing the shell. So the app prints,
/// unbuffered, and ZenticKit keeps using `Logger`.
func trace(_ category: String, _ message: @autoclosure () -> String) {
    print("[zentic:\(category)] \(message())")
    fflush(stdout)
}
