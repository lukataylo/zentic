import Foundation
import Testing

@testable import ZenticKit

@Suite("Theme validation")
struct ThemeValidationTests {

    /// A theme a model might plausibly return from "make it look cool": every
    /// numeric field out of range and text that is nearly invisible.
    static var hostileTokens: ThemeTokens {
        ThemeTokens(
            typography: .init(
                body: .systemSans,
                heading: .impact,
                mono: .courierNew,
                baseSize: 400,
                scaleRatio: 9,
                lineHeight: 0.1,
                measure: 5_000,
                letterSpacing: 3
            ),
            light: .init(
                background: "#ffffff",
                surface: "#fefefe",
                text: "#fdfdfd",  // white on white
                textMuted: "#fefefe",
                accent: "#ffffff",
                visited: "not a colour",
                border: "#eeeeee",
                codeBackground: "#f8f8f8"
            ),
            dark: .init(
                background: "#000000",
                surface: "#010101",
                text: "#020202",  // black on black
                textMuted: "#010101",
                accent: "#000000",
                visited: "#000",
                border: "#111111",
                codeBackground: "#0a0a0a"
            ),
            shape: .init(radius: 999, borderWidth: 50, elevation: .bevel),
            ornament: .init(),
            density: 40
        )
    }

    @Test("Out-of-range numbers are clamped, not rejected")
    func numericClamping() {
        let tokens = Self.hostileTokens.validated()

        #expect(tokens.typography.baseSize == 24)
        #expect(tokens.typography.scaleRatio == 1.6)
        #expect(tokens.typography.lineHeight == 1.1)
        #expect(tokens.typography.measure == 100)
        #expect(tokens.typography.letterSpacing == 0.15)
        #expect(tokens.shape.radius == 24)
        #expect(tokens.shape.borderWidth == 4)
        #expect(tokens.density == 1.6)
    }

    @Test("Illegible body text is replaced with a readable fallback")
    func contrastRepair() {
        let tokens = Self.hostileTokens.validated()

        let lightRatio = Color.contrastRatio(tokens.light.text, tokens.light.background)
        #expect(lightRatio >= ThemeTokens.Palette.minimumContrast)

        let darkRatio = Color.contrastRatio(tokens.dark.text, tokens.dark.background)
        #expect(darkRatio >= ThemeTokens.Palette.minimumContrast)
    }

    @Test("An unreadable accent falls back to body text, since links carry it")
    func accentRepair() {
        let tokens = Self.hostileTokens.validated()
        #expect(tokens.light.accent == tokens.light.text)
    }

    @Test("Unparseable colours become the fallback rather than reaching CSS")
    func malformedColour() {
        let tokens = Self.hostileTokens.validated()
        #expect(tokens.light.visited.hasPrefix("#"))
        #expect(tokens.light.visited.count == 7)
    }

    @Test("Shorthand hex is expanded")
    func shorthandHex() {
        #expect(Color.normalize("#abc") == "#aabbcc")
        #expect(Color.normalize("ABC") == "#aabbcc")
        #expect(Color.normalize("#AABBCC") == "#aabbcc")
        #expect(Color.normalize("#gg0011") == nil)
        #expect(Color.normalize("#ab") == nil)
    }

    @Test("Contrast maths matches the WCAG reference values")
    func contrastReference() {
        // Black on white is the definitional maximum, 21:1.
        #expect(abs(Color.contrastRatio("#000000", "#ffffff") - 21.0) < 0.01)
        #expect(abs(Color.contrastRatio("#ffffff", "#ffffff") - 1.0) < 0.01)
        // Unparseable input fails closed at 1:1 so the caller substitutes.
        #expect(Color.contrastRatio("bogus", "#ffffff") == 1.0)
    }

    @Test("Every shipped theme is already legible in both appearances")
    func builtInThemesAreLegible() {
        for theme in ReaderTheme.allBuiltIn {
            for (label, palette) in [("light", theme.tokens.light), ("dark", theme.tokens.dark)] {
                let ratio = Color.contrastRatio(palette.text, palette.background)
                #expect(
                    ratio >= ThemeTokens.Palette.minimumContrast,
                    "\(theme.name) \(label): body contrast \(ratio) is below AA"
                )
            }
        }
    }

    @Test("Validation is idempotent")
    func idempotent() {
        let once = Self.hostileTokens.validated()
        #expect(once.validated() == once)
    }

    @Test("Every font key yields a stack ending in a generic family")
    func fontStacksHaveGenericFallback() {
        let generics = ["sans-serif", "serif", "monospace", "cursive", "fantasy"]
        for key in FontKey.allCases {
            #expect(
                generics.contains { key.cssStack.hasSuffix($0) },
                "\(key.rawValue) stack lacks a generic fallback: \(key.cssStack)"
            )
        }
    }

    @Test("No font key references a remote resource")
    func fontStacksAreLocal() {
        // A theme must never trigger a network request; see ThemeTokens' docs.
        for key in FontKey.allCases {
            #expect(!key.cssStack.contains("url("))
            #expect(!key.cssStack.contains("//"))
        }
    }
}
