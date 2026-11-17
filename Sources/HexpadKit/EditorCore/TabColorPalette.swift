import AppKit

/// Theme-aware colours for the per-tab colour bars.
///
/// The palette follows ``TokenStylePalette``'s approach: derive every colour
/// from the system accent hue, rotating it by `0 / 0.28 / 0.50 / 0.68 / 0.85`
/// so the five choices stay distinguishable and coherent with the app's token
/// styles. Unlike the token backgrounds these are fully opaque: a 3pt tab bar
/// has to read as a solid stripe on the tab chrome in both appearances.
public enum TabColorPalette {

    /// Number of selectable colours (Apply Color 1...5).
    public static let colorCount = 5

    /// The five bar colours for `appearance`, in menu order.
    public static func colors(for appearance: NSAppearance?) -> [NSColor] {
        let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB)
            ?? NSColor.systemBlue.usingColorSpace(.deviceRGB)
            ?? NSColor.blue
        let baseHue = accent.hueComponent
        let dark = isDark(appearance)
        // A bar needs more saturation and contrast than a low-alpha background:
        // bright hues on dark chrome, deeper hues on light chrome.
        let saturation: CGFloat = dark ? 0.72 : 0.80
        let brightness: CGFloat = dark ? 0.95 : 0.62
        let offsets: [CGFloat] = [0, 0.28, 0.50, 0.68, 0.85]

        return offsets.map { offset in
            var hue = (baseHue + offset).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
            return NSColor(hue: hue,
                           saturation: saturation,
                           brightness: brightness,
                           alpha: 1)
        }
    }

    /// The bar colour for `index` (1...5), or `nil` when no colour is set.
    public static func color(for index: Int, appearance: NSAppearance?) -> NSColor? {
        let colors = colors(for: appearance)
        guard index >= 1, index <= colors.count else { return nil }
        return colors[index - 1]
    }

    /// Whether `appearance` is a dark appearance (unknown appearances are
    /// treated as light, matching the editor's default theme).
    static func isDark(_ appearance: NSAppearance?) -> Bool {
        guard let appearance else { return false }
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
