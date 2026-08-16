import AppKit
import ZenticKit

// How the ladder describes itself. Kept in the Mac target because ZenticKit is
// "all model and policy logic, no UI" — and because iOS will want different
// wording for the same five stops.

extension PageLevel {
    var title: String {
        switch self {
        case .original: "Original"
        case .clean: "Clean"
        case .calm: "Calm"
        case .reader: "Reader"
        case .rewritten: "Rewritten"
        }
    }

    /// One line, in the popover, under the slider.
    ///
    /// Every one of these describes **state**, never a count. `WKContentRuleList`
    /// reports nothing back to the app, so "312 trackers blocked" would be a number
    /// we invented — invariant 8. This is the most likely place in the product for
    /// someone to write one.
    var summary: String {
        switch self {
        case .original:
            "The site exactly as it shipped. Nothing blocked, nothing dismissed."
        case .clean:
            "Ads and trackers blocked. The site's own layout, untouched."
        case .calm:
            "Also the interstitials and the chum, and cookie walls answered for you."
        case .reader:
            "Rebuilt in Zentic's type and spacing. Every word is still the publisher's."
        case .rewritten:
            "Also re-voiced by a model. Badged while shown, and ⌘\\ brings the original back."
        }
    }

}
