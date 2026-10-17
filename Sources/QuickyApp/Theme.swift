import AppKit
import CoreText
import SwiftUI

/// Raycast's bundled Midnight theme and its role mapping (ui-spec v4). No other colour literals.
enum Theme {
    static let foreground = Color(hex: 0xFAF0FF)
    static let accent = Color(hex: 0x4FA3F8)
    static let loader = Color(hex: 0xF4C4FF)
    static let green = Color(hex: 0x63BA89)
    static let red = Color(hex: 0xF84141)
    static let purple = Color(hex: 0xC58AFA)

    static let textPrimary = foreground
    static let textSecondary = foreground.opacity(0.6)
    static let textTertiary = foreground.opacity(0.4)

    static let surfaceControl = foreground.opacity(0.1)
    static let surfaceActionBar = Color.white.opacity(0.05)
    static let borderPanel = foreground.opacity(0.2)
    static let borderSeparator = foreground.opacity(0.1)

    static let windowBg = Color(hex: 0x070034).opacity(0.4)
    static let windowBgSecondary = Color(hex: 0x11005B).opacity(0.4)
    static let windowBase = Color(hex: 0x262626)

    static let panelWidth: CGFloat = 560
    static let panelRadius: CGFloat = 20
    static let rowRadius: CGFloat = 12
    static let inputHeight: CGFloat = 56
    static let footerHeight: CGFloat = 44
    /// Lead column is x 16 to 40; every text column starts at 16 + 24 + 12 = 52.
    static let inset: CGFloat = 16
    static let leadWidth: CGFloat = 24
    static let leadGap: CGFloat = 12
    static let textX: CGFloat = inset + leadWidth + leadGap
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Geist type ramp: sizes 11/13/16 only, tracking -1%.
struct TypeStyle: Sendable {
    let postScriptName: String
    let size: CGFloat
    let lineHeight: CGFloat

    static let input = TypeStyle(postScriptName: "Geist-Regular", size: 16, lineHeight: 24)
    static let body = TypeStyle(postScriptName: "Geist-Regular", size: 13, lineHeight: 20)
    static let bodyStrong = TypeStyle(postScriptName: "Geist-Medium", size: 13, lineHeight: 20)
    static let key = TypeStyle(postScriptName: "GeistMono-Medium", size: 11, lineHeight: 12)
    static let mono = TypeStyle(postScriptName: "GeistMono-Regular", size: 13, lineHeight: 20)

    var font: Font { .custom(postScriptName, fixedSize: size) }

    /// SwiftUI has no line-height modifier, so the gap between the font's natural line and the
    /// ramp's line height becomes line spacing plus half of it above and below.
    var extraLeading: CGFloat {
        guard let ns = NSFont(name: postScriptName, size: size) else { return 0 }
        return max(0, lineHeight - (ns.ascender - ns.descender + ns.leading))
    }
}

extension View {
    func type(_ style: TypeStyle) -> some View {
        font(style.font)
            .tracking(-0.01 * style.size)
            .lineSpacing(style.extraLeading)
            .padding(.vertical, style.extraLeading / 2)
    }
}

enum Fonts {
    /// The app passes its bundle's `Resources/Fonts`; tests pass the repo's `Resources/Fonts`.
    static func register(from directory: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
