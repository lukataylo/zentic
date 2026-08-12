import Foundation

/// Shipped themes.
///
/// These double as few-shot examples for theme generation: a prompt like
/// "make it look like a 1997 fan page" is far more reliably answered by a small
/// on-device model when it has ``retro90s`` in front of it as a worked example of
/// what an extreme-but-valid token set looks like.
extension ReaderTheme {
    public static let allBuiltIn: [ReaderTheme] = [
        .zentic, .cupertino, .newsprint, .retro90s, .terminal, .paper,
    ]

    /// The default. Deliberately unopinionated — it should read as "the content,
    /// well set" rather than as a design with a point of view.
    public static let zentic = ReaderTheme(
        id: "builtin.zentic",
        name: "Zentic",
        source: .builtIn,
        tokens: ThemeTokens(
            typography: .init(
                body: .systemSans,
                heading: .systemSans,
                mono: .systemMono,
                baseSize: 17,
                scaleRatio: 1.25,
                lineHeight: 1.65,
                measure: 68
            ),
            light: .init(
                background: "#ffffff",
                surface: "#f7f7f5",
                text: "#1c1c1e",
                textMuted: "#6b6b70",
                accent: "#2f6fed",
                visited: "#6b4fbb",
                border: "#e3e3e0",
                codeBackground: "#f4f4f2"
            ),
            dark: .init(
                background: "#141416",
                surface: "#1e1e21",
                text: "#ececf0",
                textMuted: "#9a9aa2",
                accent: "#7aa2f7",
                visited: "#b9a0f0",
                border: "#2c2c31",
                codeBackground: "#1a1a1d"
            ),
            shape: .init(radius: 10, borderWidth: 1, elevation: .subtle),
            ornament: .init(rule: .hairline, listMarker: .disc, linkDecoration: .underline)
        )
    )

    /// Apple's editorial register: system type, wide leading, restrained colour,
    /// generous whitespace, links carried by colour rather than underline.
    public static let cupertino = ReaderTheme(
        id: "builtin.cupertino",
        name: "Cupertino",
        source: .builtIn,
        tokens: ThemeTokens(
            typography: .init(
                body: .systemSans,
                heading: .systemSans,
                mono: .systemMono,
                baseSize: 19,
                scaleRatio: 1.32,
                lineHeight: 1.72,
                measure: 62,
                letterSpacing: -0.011
            ),
            light: .init(
                background: "#ffffff",
                surface: "#f5f5f7",
                text: "#1d1d1f",
                textMuted: "#6e6e73",
                accent: "#0071e3",
                visited: "#0071e3",
                border: "#d2d2d7",
                codeBackground: "#f5f5f7"
            ),
            dark: .init(
                background: "#000000",
                surface: "#1d1d1f",
                text: "#f5f5f7",
                textMuted: "#a1a1a6",
                accent: "#2997ff",
                visited: "#2997ff",
                border: "#424245",
                codeBackground: "#1d1d1f"
            ),
            shape: .init(radius: 18, borderWidth: 0, elevation: .subtle),
            ornament: .init(
                rule: .hairline,
                listMarker: .disc,
                linkDecoration: .none,
                headingCase: .asIs
            ),
            density: 1.3
        )
    )

    /// Print editorial: serif, justified with hyphenation, drop cap, double rules.
    public static let newsprint = ReaderTheme(
        id: "builtin.newsprint",
        name: "Newsprint",
        source: .builtIn,
        tokens: ThemeTokens(
            typography: .init(
                body: .charter,
                heading: .georgia,
                mono: .courierNew,
                baseSize: 18,
                scaleRatio: 1.4,
                lineHeight: 1.55,
                measure: 74
            ),
            light: .init(
                background: "#fbfaf7",
                surface: "#f2f0ea",
                text: "#1a1a18",
                textMuted: "#5f5d57",
                accent: "#8c2f22",
                visited: "#6b2419",
                border: "#d8d4c8",
                codeBackground: "#f2f0ea"
            ),
            dark: .init(
                background: "#171613",
                surface: "#211f1b",
                text: "#eae7de",
                textMuted: "#9c988c",
                accent: "#d9705e",
                visited: "#c08a7d",
                border: "#33302a",
                codeBackground: "#211f1b"
            ),
            shape: .init(radius: 0, borderWidth: 1, elevation: .none),
            ornament: .init(
                rule: .double,
                listMarker: .dash,
                linkDecoration: .underline,
                headingCase: .asIs,
                dropCap: true,
                justify: true
            )
        )
    )

    /// The late-90s web, played straight: Times body, Impact headings, blue and
    /// purple links, grooved rules, hard bevels, square corners, and no measure
    /// discipline whatsoever.
    public static let retro90s = ReaderTheme(
        id: "builtin.retro90s",
        name: "1997",
        source: .builtIn,
        tokens: ThemeTokens(
            typography: .init(
                body: .timesNewRoman,
                heading: .impact,
                mono: .courierNew,
                baseSize: 16,
                scaleRatio: 1.5,
                lineHeight: 1.25,
                measure: 100
            ),
            light: .init(
                background: "#c0c0c0",
                surface: "#ffffff",
                text: "#000000",
                textMuted: "#404040",
                accent: "#0000ee",
                visited: "#551a8b",
                border: "#808080",
                codeBackground: "#ffffcc"
            ),
            dark: .init(
                background: "#1a1a1a",
                surface: "#000080",
                text: "#e0e0e0",
                textMuted: "#a0a0a0",
                accent: "#00ffff",
                visited: "#ff80ff",
                border: "#808080",
                codeBackground: "#000000"
            ),
            shape: .init(radius: 0, borderWidth: 2, elevation: .bevel),
            ornament: .init(
                rule: .groove,
                listMarker: .square,
                linkDecoration: .underline,
                headingCase: .upper
            ),
            density: 0.8
        )
    )

    public static let terminal = ReaderTheme(
        id: "builtin.terminal",
        name: "Terminal",
        source: .builtIn,
        tokens: ThemeTokens(
            typography: .init(
                body: .systemMono,
                heading: .systemMono,
                mono: .systemMono,
                baseSize: 15,
                scaleRatio: 1.15,
                lineHeight: 1.5,
                measure: 84
            ),
            light: .init(
                background: "#f8f8f2",
                surface: "#eeeee8",
                text: "#1b1b1b",
                textMuted: "#5a5a5a",
                accent: "#007020",
                visited: "#6a3ea1",
                border: "#d0d0c8",
                codeBackground: "#eeeee8"
            ),
            dark: .init(
                background: "#0c0f0c",
                surface: "#141814",
                text: "#c8e6c9",
                textMuted: "#7a9c7c",
                accent: "#5fe36b",
                visited: "#a8d8a8",
                border: "#1f261f",
                codeBackground: "#141814"
            ),
            shape: .init(radius: 0, borderWidth: 1, elevation: .none),
            ornament: .init(
                rule: .dashed,
                listMarker: .arrow,
                linkDecoration: .dotted,
                headingCase: .upper
            ),
            density: 0.9
        )
    )

    public static let paper = ReaderTheme(
        id: "builtin.paper",
        name: "Paper",
        source: .builtIn,
        tokens: ThemeTokens(
            typography: .init(
                body: .systemSerif,
                heading: .systemSerif,
                mono: .menlo,
                baseSize: 19,
                scaleRatio: 1.28,
                lineHeight: 1.7,
                measure: 66
            ),
            light: .init(
                background: "#fdfbf6",
                surface: "#f5f1e8",
                text: "#2b2721",
                textMuted: "#6f6659",
                accent: "#9a6b3f",
                visited: "#7d5230",
                border: "#e6dfd0",
                codeBackground: "#f5f1e8"
            ),
            dark: .init(
                background: "#1a1815",
                surface: "#232019",
                text: "#ece5d8",
                textMuted: "#a49b88",
                accent: "#d4a373",
                visited: "#c08f6a",
                border: "#302b23",
                codeBackground: "#232019"
            ),
            shape: .init(radius: 4, borderWidth: 1, elevation: .none),
            ornament: .init(rule: .hairline, listMarker: .circle, linkDecoration: .underline),
            density: 1.15
        )
    )
}
