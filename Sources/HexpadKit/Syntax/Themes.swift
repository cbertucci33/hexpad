import Foundation
import AppKit

/// Built-in syntax highlighting themes
public enum HexpadTheme: String, CaseIterable, Identifiable {
    case light = "Light"
    case dark = "Dark"
    case classic = "Classic"
    case monokai = "Monokai"
    
    public var id: String { rawValue }
    
    /// Resolves the built-in theme for an AppKit appearance. System mode,
    /// explicit Light/Dark overrides, and high-contrast variants all land on a
    /// matching foreground/background pair instead of the old hardcoded dark
    /// theme (which rendered white text on a white light-mode background).
    public static func forAppearance(_ appearance: NSAppearance) -> Theme {
        let candidates: [NSAppearance.Name] = [
            .darkAqua, .accessibilityHighContrastDarkAqua,
            .aqua, .accessibilityHighContrastAqua
        ]
        let match = appearance.bestMatch(from: candidates)
        let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        return (isDark ? HexpadTheme.dark : HexpadTheme.light).theme
    }

    public var theme: Theme {
        switch self {
        case .light:
            return Theme(
                name: "Light",
                colors: [
                    .keyword: NSColor(red: 0, green: 0.3, blue: 0.8, alpha: 1),
                    .string: NSColor(red: 0.4, green: 0.2, blue: 0.8, alpha: 1),
                    .comment: NSColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1),
                    .number: NSColor(red: 0.6, green: 0.2, blue: 0.2, alpha: 1),
                    .type: NSColor(red: 0, green: 0.5, blue: 0.3, alpha: 1),
                    .function: NSColor(red: 0.8, green: 0.4, blue: 0, alpha: 1),
                    .variable: NSColor.black,
                    .operator: NSColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1),
                    .punctuation: NSColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1),
                    .whitespace: NSColor.clear,
                    .plain: NSColor.black
                ],
                background: .white,
                foreground: .black
            )
        case .dark:
            return Theme(
                name: "Dark",
                colors: [
                    .keyword: NSColor(red: 0.4, green: 0.6, blue: 1, alpha: 1),
                    .string: NSColor(red: 0.7, green: 0.8, blue: 0.4, alpha: 1),
                    .comment: NSColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1),
                    .number: NSColor(red: 0.9, green: 0.5, blue: 0.5, alpha: 1),
                    .type: NSColor(red: 0.5, green: 0.8, blue: 0.6, alpha: 1),
                    .function: NSColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1),
                    .variable: NSColor.white,
                    .operator: NSColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1),
                    .punctuation: NSColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1),
                    .whitespace: NSColor.clear,
                    .plain: NSColor.white
                ],
                background: NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1),
                foreground: NSColor.white
            )
        case .classic:
            return Theme(
                name: "Classic",
                colors: [
                    .keyword: NSColor(red: 0, green: 0, blue: 0.8, alpha: 1),
                    .string: NSColor(red: 0.6, green: 0, blue: 0.6, alpha: 1),
                    .comment: NSColor(red: 0, green: 0.5, blue: 0, alpha: 1),
                    .number: NSColor(red: 0.6, green: 0.3, blue: 0, alpha: 1),
                    .type: NSColor(red: 0, green: 0.5, blue: 0.5, alpha: 1),
                    .function: NSColor(red: 0.8, green: 0.4, blue: 0, alpha: 1),
                    .variable: NSColor.black,
                    .operator: NSColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1),
                    .punctuation: NSColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1),
                    .whitespace: NSColor.clear,
                    .plain: NSColor.black
                ],
                background: NSColor(red: 1, green: 1, blue: 0.95, alpha: 1),
                foreground: NSColor.black
            )
        case .monokai:
            return Theme(
                name: "Monokai",
                colors: [
                    .keyword: NSColor(red: 0.7, green: 0.3, blue: 0.8, alpha: 1),
                    .string: NSColor(red: 0.6, green: 0.8, blue: 0.4, alpha: 1),
                    .comment: NSColor(red: 0.4, green: 0.5, blue: 0.4, alpha: 1),
                    .number: NSColor(red: 0.9, green: 0.6, blue: 0.3, alpha: 1),
                    .type: NSColor(red: 0.7, green: 0.6, blue: 0.4, alpha: 1),
                    .function: NSColor(red: 0.5, green: 0.7, blue: 0.9, alpha: 1),
                    .variable: NSColor.white,
                    .operator: NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1),
                    .punctuation: NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1),
                    .whitespace: NSColor.clear,
                    .plain: NSColor.white
                ],
                background: NSColor(red: 0.2, green: 0.18, blue: 0.18, alpha: 1),
                foreground: NSColor.white
            )
        }
    }
}
