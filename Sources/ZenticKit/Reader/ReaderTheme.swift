import Foundation
import FoundationModels

/// How the restructured page *looks*, independent of what it says.
///
/// Two orthogonal axes, and conflating them would be a design error:
/// ``Tone`` changes the words (a rewrite — it alters meaning, needs consent, gets
/// badged). A theme changes only presentation. Restyling is lossless and
/// reversible, so it needs none of that ceremony and can be applied freely.
///
/// Themes come from a built-in preset or from a user prompt — "make it look like
/// Apple docs", "1997 GeoCities", "newsprint".
public struct ReaderTheme: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var source: Source
    public var tokens: ThemeTokens
    /// The prompt that produced this theme, when generated. Kept so it can be
    /// re-generated after the token schema changes, and shown in the UI.
    public var prompt: String?
    public var createdAt: Date

    public init(
        id: String,
        name: String,
        source: Source,
        tokens: ThemeTokens,
        prompt: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.tokens = tokens
        self.prompt = prompt
        self.createdAt = createdAt
    }

    public enum Source: String, Codable, Sendable {
        /// Shipped with the app.
        case builtIn
        /// Produced by a model from ``ReaderTheme/prompt``.
        case generated
        /// Hand-edited by the user.
        case userEdited
    }
}

// MARK: - Tokens

/// The complete vocabulary a theme can express.
///
/// **A model never emits CSS.** It fills in this structure, which is then
/// validated and compiled to CSS by the render layer. That boundary is load-bearing:
///
/// - **Privacy.** Free-form CSS can contain `url(…)`, and a single
///   `background-image` would beacon to an arbitrary host on every page the user
///   reads. Tokens cannot express a network request.
/// - **Legibility.** Ranges are clamped and text/background pairs are contrast-checked
///   (see ``ThemeTokens/validated()``), so a generated theme cannot produce grey-on-grey.
///   Arbitrary CSS offers no such guarantee.
/// - **Robustness.** A malformed token is clamped to a sane value; malformed CSS
///   silently breaks the page.
/// - **Cost.** This structure is small enough for an on-device model to fill in
///   reliably with guided generation.
@Generable
public struct ThemeTokens: Codable, Sendable, Hashable {
    public var typography: Typography
    public var light: Palette
    public var dark: Palette
    public var shape: Shape
    public var ornament: Ornament
    /// Multiplier on the base spacing scale. 0.6 is dense, 1.6 is airy.
    public var density: Double

    public init(
        typography: Typography,
        light: Palette,
        dark: Palette,
        shape: Shape,
        ornament: Ornament,
        density: Double = 1.0
    ) {
        self.typography = typography
        self.light = light
        self.dark = dark
        self.shape = shape
        self.ornament = ornament
        self.density = density
    }

    @Generable
    public struct Typography: Codable, Sendable, Hashable {
        public var body: FontKey
        public var heading: FontKey
        public var mono: FontKey
        /// Body size in points, 13...24.
        public var baseSize: Double
        /// Ratio between steps of the heading scale, 1.05...1.6.
        public var scaleRatio: Double
        /// Body line height as a multiple of font size, 1.1...2.0.
        public var lineHeight: Double
        /// Maximum line length in `ch`, 45...100. Around 70 is comfortable.
        public var measure: Double
        /// Body letter spacing in em, -0.03...0.15.
        public var letterSpacing: Double

        public init(
            body: FontKey,
            heading: FontKey,
            mono: FontKey,
            baseSize: Double = 17,
            scaleRatio: Double = 1.25,
            lineHeight: Double = 1.6,
            measure: Double = 70,
            letterSpacing: Double = 0
        ) {
            self.body = body
            self.heading = heading
            self.mono = mono
            self.baseSize = baseSize
            self.scaleRatio = scaleRatio
            self.lineHeight = lineHeight
            self.measure = measure
            self.letterSpacing = letterSpacing
        }
    }

    /// Colours for one appearance. Hex strings, `#rrggbb`.
    @Generable
    public struct Palette: Codable, Sendable, Hashable {
        public var background: String
        public var surface: String
        public var text: String
        public var textMuted: String
        public var accent: String
        public var visited: String
        public var border: String
        public var codeBackground: String

        public init(
            background: String,
            surface: String,
            text: String,
            textMuted: String,
            accent: String,
            visited: String,
            border: String,
            codeBackground: String
        ) {
            self.background = background
            self.surface = surface
            self.text = text
            self.textMuted = textMuted
            self.accent = accent
            self.visited = visited
            self.border = border
            self.codeBackground = codeBackground
        }
    }

    @Generable
    public struct Shape: Codable, Sendable, Hashable {
        /// Corner radius in points, 0...24. Zero is what makes retro themes work.
        public var radius: Double
        /// Border width in points, 0...4.
        public var borderWidth: Double
        public var elevation: Elevation

        public init(radius: Double = 8, borderWidth: Double = 1, elevation: Elevation = .subtle) {
            self.radius = radius
            self.borderWidth = borderWidth
            self.elevation = elevation
        }

        @Generable
        public enum Elevation: String, Codable, Sendable, CaseIterable {
            case none
            case subtle
            case raised
            /// Hard 3D bevel, no blur — the Windows 95 / early-web look.
            case bevel
        }
    }

    @Generable
    public struct Ornament: Codable, Sendable, Hashable {
        public var rule: RuleStyle
        public var listMarker: ListMarker
        public var linkDecoration: LinkDecoration
        public var headingCase: HeadingCase
        /// Drop cap on the first paragraph. Editorial themes want this.
        public var dropCap: Bool
        /// Justify body text with hyphenation. Newsprint wants this; screens
        /// usually do not.
        public var justify: Bool

        public init(
            rule: RuleStyle = .hairline,
            listMarker: ListMarker = .disc,
            linkDecoration: LinkDecoration = .underline,
            headingCase: HeadingCase = .asIs,
            dropCap: Bool = false,
            justify: Bool = false
        ) {
            self.rule = rule
            self.listMarker = listMarker
            self.linkDecoration = linkDecoration
            self.headingCase = headingCase
            self.dropCap = dropCap
            self.justify = justify
        }

        @Generable
        public enum RuleStyle: String, Codable, Sendable, CaseIterable {
            case none, hairline, solid, double, dashed, groove, ridge
        }

        @Generable
        public enum ListMarker: String, Codable, Sendable, CaseIterable {
            case disc, circle, square, dash, arrow, none
        }

        @Generable
        public enum LinkDecoration: String, Codable, Sendable, CaseIterable {
            case none, underline, thickUnderline, dotted, highlight
        }

        @Generable
        public enum HeadingCase: String, Codable, Sendable, CaseIterable {
            case asIs, upper, smallCaps
        }
    }
}

// MARK: - Fonts

/// Fonts a theme may name.
///
/// A closed set of families present on every Apple platform, rather than a free
/// string. Two reasons: an arbitrary family name would silently fall back to
/// something unintended, and any design that permits a family name eventually
/// wants a webfont URL — which means a network request per page, breaking both
/// offline rendering and the privacy guarantee. Everything here is local.
@Generable
public enum FontKey: String, Codable, Sendable, CaseIterable {
    // Sans
    case systemSans
    case helveticaNeue
    case avenirNext
    case optima
    case futura
    case gillSans
    case verdana
    case arial
    // Serif
    case systemSerif
    case georgia
    case palatino
    case timesNewRoman
    case charter
    case americanTypewriter
    // Mono
    case systemMono
    case menlo
    case monaco
    case courierNew
    // Display and period pieces
    case impact
    case comicSans
    case markerFelt
    case chalkboard
    case copperplate
    case papyrus

    /// CSS `font-family` stack, always ending in a generic family.
    public var cssStack: String {
        switch self {
        case .systemSans: "system-ui, -apple-system, sans-serif"
        case .helveticaNeue: "\"Helvetica Neue\", Helvetica, sans-serif"
        case .avenirNext: "\"Avenir Next\", Avenir, sans-serif"
        case .optima: "Optima, sans-serif"
        case .futura: "Futura, sans-serif"
        case .gillSans: "\"Gill Sans\", \"Gill Sans MT\", sans-serif"
        case .verdana: "Verdana, Geneva, sans-serif"
        case .arial: "Arial, Helvetica, sans-serif"
        case .systemSerif: "ui-serif, \"New York\", Georgia, serif"
        case .georgia: "Georgia, serif"
        case .palatino: "Palatino, \"Palatino Linotype\", serif"
        case .timesNewRoman: "\"Times New Roman\", Times, serif"
        case .charter: "Charter, Georgia, serif"
        case .americanTypewriter: "\"American Typewriter\", Georgia, serif"
        case .systemMono: "ui-monospace, \"SF Mono\", Menlo, monospace"
        case .menlo: "Menlo, monospace"
        case .monaco: "Monaco, monospace"
        case .courierNew: "\"Courier New\", Courier, monospace"
        case .impact: "Impact, \"Haettenschweiler\", sans-serif"
        case .comicSans: "\"Comic Sans MS\", \"Chalkboard SE\", cursive"
        case .markerFelt: "\"Marker Felt\", cursive"
        case .chalkboard: "\"Chalkboard SE\", \"Comic Sans MS\", cursive"
        case .copperplate: "Copperplate, \"Copperplate Gothic Light\", fantasy"
        case .papyrus: "Papyrus, fantasy"
        }
    }
}

// MARK: - Validation

extension ThemeTokens {
    /// Clamp every numeric field to its documented range, normalise colours, and
    /// repair unreadable text/background pairs.
    ///
    /// Applied to **all** tokens, not just generated ones — a hand-edited theme
    /// can be just as broken as an inferred one, and the render layer should only
    /// ever receive tokens that are known good.
    public func validated() -> ThemeTokens {
        var copy = self

        copy.typography.baseSize = typography.baseSize.clamped(to: 13...24)
        copy.typography.scaleRatio = typography.scaleRatio.clamped(to: 1.05...1.6)
        copy.typography.lineHeight = typography.lineHeight.clamped(to: 1.1...2.0)
        copy.typography.measure = typography.measure.clamped(to: 45...100)
        copy.typography.letterSpacing = typography.letterSpacing.clamped(to: -0.03...0.15)
        copy.shape.radius = shape.radius.clamped(to: 0...24)
        copy.shape.borderWidth = shape.borderWidth.clamped(to: 0...4)
        copy.density = density.clamped(to: 0.6...1.6)
        copy.light = light.legible(fallbackText: "#1a1a1a", fallbackBackground: "#ffffff")
        copy.dark = dark.legible(fallbackText: "#f2f2f2", fallbackBackground: "#141414")

        return copy
    }
}

extension ThemeTokens.Palette {
    /// Minimum body-text contrast ratio. WCAG AA for body copy.
    public static let minimumContrast: Double = 4.5
    /// Muted text is secondary, so it is held to the large-text threshold.
    public static let minimumMutedContrast: Double = 3.0

    /// Normalise hex values and force text colours to be readable against the
    /// background, substituting a fallback when a generated pair is too close.
    func legible(fallbackText: String, fallbackBackground: String) -> Self {
        var copy = self
        copy.background = Color.normalize(background) ?? fallbackBackground
        copy.surface = Color.normalize(surface) ?? copy.background
        copy.text = Color.normalize(text) ?? fallbackText
        copy.textMuted = Color.normalize(textMuted) ?? copy.text
        copy.accent = Color.normalize(accent) ?? copy.text
        copy.visited = Color.normalize(visited) ?? copy.accent
        copy.border = Color.normalize(border) ?? copy.textMuted
        copy.codeBackground = Color.normalize(codeBackground) ?? copy.surface

        if Color.contrastRatio(copy.text, copy.background) < Self.minimumContrast {
            copy.text = fallbackText
        }
        if Color.contrastRatio(copy.textMuted, copy.background) < Self.minimumMutedContrast {
            copy.textMuted = copy.text
        }
        // An unreadable accent is worse than no accent, since links carry it.
        if Color.contrastRatio(copy.accent, copy.background) < Self.minimumMutedContrast {
            copy.accent = copy.text
        }

        return copy
    }
}

/// Minimal colour maths for token validation.
enum Color {
    /// Parse `#rgb`, `#rrggbb` or bare hex; return canonical `#rrggbb`.
    static func normalize(_ value: String) -> String? {
        let hex = value.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: "#", with: "")

        let expanded: String
        switch hex.count {
        case 3: expanded = hex.map { "\($0)\($0)" }.joined()
        case 6: expanded = hex
        default: return nil
        }

        guard expanded.allSatisfy(\.isHexDigit) else { return nil }
        return "#\(expanded)"
    }

    static func components(_ value: String) -> (r: Double, g: Double, b: Double)? {
        guard let hex = normalize(value) else { return nil }
        let digits = hex.dropFirst()
        guard let raw = Int(digits, radix: 16) else { return nil }
        return (
            Double((raw >> 16) & 0xFF) / 255,
            Double((raw >> 8) & 0xFF) / 255,
            Double(raw & 0xFF) / 255
        )
    }

    /// WCAG 2.1 relative luminance.
    static func luminance(_ value: String) -> Double? {
        guard let (r, g, b) = components(value) else { return nil }
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio, 1...21. Returns 1 for unparseable input, which fails
    /// closed — the caller substitutes its fallback.
    static func contrastRatio(_ a: String, _ b: String) -> Double {
        guard let la = luminance(a), let lb = luminance(b) else { return 1 }
        let lighter = max(la, lb)
        let darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

extension Double {
    /// Clamp into `range`, treating a non-finite value as out of range entirely.
    ///
    /// `min`/`max` propagate `NaN` rather than ordering it, so the obvious
    /// implementation lets `NaN` through a clamp untouched and straight into a
    /// generated stylesheet, where it silently invalidates the declaration it
    /// lands in. A model cannot emit `NaN` through JSON, but the invariant here is
    /// that a validated token is *always* in range, and a guarantee with a hole
    /// that only in-process callers can reach is the kind that rots quietly.
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
