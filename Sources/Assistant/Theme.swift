import AppKit
import SwiftUI
import CoreText

/// Raycast's bundled Midnight theme, with its role mapping (ui-spec v4). No other colour literals.
enum Theme {
    static let background = Color(hex: 0x070034)
    static let backgroundSecondary = Color(hex: 0x11005B)
    static let foreground = Color(hex: 0xFAF0FF)
    static let accent = Color(hex: 0x4FA3F8)
    static let selection = Color(hex: 0xB1A7FF)
    static let loader = Color(hex: 0xF4C4FF)
    static let green = Color(hex: 0x63BA89)
    static let red = Color(hex: 0xF84141)
    static let orange = Color(hex: 0xFFC100)
    static let purple = Color(hex: 0xC58AFA)

    static let textPrimary = foreground
    static let textSecondary = foreground.opacity(0.6)
    static let textTertiary = foreground.opacity(0.4)
    static let textQuaternary = foreground.opacity(0.2)

    static let listSelection = foreground.opacity(0.10)
    static let listHover = foreground.opacity(0.05)
    static let control = foreground.opacity(0.10)
    static let actionBar = Color.white.opacity(0.05)
    static let borderPanel = foreground.opacity(0.20)
    static let separator = foreground.opacity(0.10)
    static let keycapBorder = foreground.opacity(0.25)
    static let keycapFill = foreground.opacity(0.03)
    static let chipFill = foreground.opacity(0.08)
    static let chipBorder = foreground.opacity(0.10)

    static let windowBg = background.opacity(0.40)
    static let windowBgSecondary = backgroundSecondary.opacity(0.40)
    static let windowBase = Color(hex: 0x262626)

    // Semantic
    static let listening = purple
    static let working = loader
    static let done = green
    static let error = red
    static let link = accent
}

/// The one grid (ui-spec v4).
enum Grid {
    static let panelWidth: CGFloat = 560
    static let panelRadius: CGFloat = 20
    static let leadX: CGFloat = 16          // lead column 16…40, icon centre 28
    static let lead: CGFloat = 24
    static let textX: CGFloat = 52          // 16 + 24 + 12
    static let gap: CGFloat = 12
    static let inset: CGFloat = 16
    static let rowInset: CGFloat = 8
    static let rowRadius: CGFloat = 12
    static let rowHeight: CGFloat = 32
    static let inputHeight: CGFloat = 56    // the bottom bar: 16 + 24 + 16
    static let keycapRadius: CGFloat = 6
    static let keycapHeight: CGFloat = 22
    static let chipHeight: CGFloat = 28
    static let popoverWidth: CGFloat = 320
    static let popoverRadius: CGFloat = 16
    static let popoverRowHeight: CGFloat = 36
    static let popoverRowRadius: CGFloat = 10
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Type

enum Fonts {
    static func register() {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Fonts")) }
        // `swift run` from the package directory
        dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Fonts"))
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "ttf" || f.pathExtension == "otf" {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
            if !files.isEmpty { return }
        }
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium: name = "Geist-Medium"
        case .semibold: name = "Geist-SemiBold"
        default: name = "Geist-Regular"
        }
        if NSFont(name: name, size: size) != nil { return .custom(name, fixedSize: size) }
        return .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        let name = weight == .medium ? "GeistMono-Medium" : "GeistMono-Regular"
        if NSFont(name: name, size: size) != nil { return .custom(name, fixedSize: size) }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static let input = sans(16)
    static let body = sans(13)
    static let bodyStrong = sans(13, .medium)
    static let title = sans(13, .semibold)
    static let key = mono(11, .medium)
    static let metric = mono(11, .regular)
}

extension View {
    /// Raycast's -0.01em tracking.
    func tracked(_ size: CGFloat) -> some View { self.tracking(-0.01 * size) }
}

// MARK: - Icons (Hugeicons stroke 1.5, drawn from generated paths)

struct Icon: View {
    let name: String
    var size: CGFloat = 16
    var color: Color = Theme.textSecondary

    var body: some View {
        IconShape(name: name)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5 * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

struct IconShape: Shape {
    let name: String
    func path(in rect: CGRect) -> Path {
        guard let cg = IconPaths.path(name) else { return Path() }
        let s = min(rect.width, rect.height) / 24
        var t = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: s, y: s)
        guard let scaled = cg.copy(using: &t) else { return Path() }
        return Path(scaled)
    }
}

/// Rotating loading-03 in the loader colour (800 ms per turn).
struct Spinner: View {
    var size: CGFloat = 16
    @State private var spin = false
    var body: some View {
        Icon(name: "loading", size: size, color: Theme.loader)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

/// Menu bar template image drawn from the same "?" path.
enum MenuBarIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext, let p = IconPaths.path("question") else { return false }
            let s = rect.width / 24
            ctx.scaleBy(x: s, y: s)
            ctx.addPath(p)
            ctx.setLineWidth(1.5 * 24 / 18)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.strokePath()
            return true
        }
        img.isTemplate = true
        return img
    }
}
