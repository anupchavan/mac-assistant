import AppKit
import SwiftUI

/// The agent's own cursor (like Codex's): a drawn pointer in a click-through overlay that glides to each
/// target and pulses when it acts. The user's real cursor is never moved, so they can keep working.
@MainActor
final class AgentCursor {
    static let shared = AgentCursor()

    private final class Model: ObservableObject {
        @Published var label = ""
        @Published var pulse = 0
    }

    private var window: NSPanel?
    private var host: NSHostingView<CursorView>?
    private let model = Model()
    private static let size = CGSize(width: 220, height: 44)
    private static let tip = CGPoint(x: 6, y: 6)            // the arrow's tip inside the view (top-left origin)

    /// Screen points use CG coordinates (top-left origin of the primary display), like the executor.
    func show(at p: CGPoint) {
        if window == nil { makeWindow() }
        place(p, animated: false)
        window?.orderFrontRegardless()
    }

    /// Glide to `p` (eased, 0.25–0.55 s by distance), then wait for it to land.
    func move(to p: CGPoint, label: String) async {
        if window == nil { show(at: CGEvent(source: nil)?.location ?? p) }
        model.label = label
        let from = currentPoint ?? p
        let d = hypot(p.x - from.x, p.y - from.y)
        let duration = min(0.55, max(0.25, d / 1800))
        place(p, animated: true, duration: duration)
        try? await Task.sleep(nanoseconds: UInt64(duration * 1e9))
    }

    func click() { model.pulse += 1 }

    /// For `--probe render`: the cursor with a label, drawn without the overlay window.
    static func preview(label: String) -> some View {
        let m = Model(); m.label = label
        return CursorView(model: m)
    }

    func hide() {
        window?.orderOut(nil)
        currentPoint = nil
    }

    // MARK: -

    private var currentPoint: CGPoint?

    private func makeWindow() {
        let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true                     // click-through: never in the way
        w.sharingType = .none                           // never in screenshots, including the agent's own
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let h = NSHostingView(rootView: CursorView(model: model))
        h.frame = NSRect(origin: .zero, size: Self.size)
        root.addSubview(h)
        w.contentView = root
        window = w
        host = h
    }

    private func place(_ p: CGPoint, animated: Bool, duration: Double = 0.3) {
        guard let window, let host else { return }
        currentPoint = p
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        // CG (top-left) → AppKit (bottom-left) → this window's coordinates, tip on the point.
        let appKit = CGPoint(x: p.x, y: primaryH - p.y)
        let origin = CGPoint(x: appKit.x - window.frame.minX - Self.tip.x,
                             y: appKit.y - window.frame.minY - (Self.size.height - Self.tip.y))
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
                host.animator().setFrameOrigin(origin)
            }
        } else {
            host.setFrameOrigin(origin)
        }
    }

    private struct CursorView: View {
        @ObservedObject var model: Model
        @State private var ring = true      // true = expanded and invisible (rest); a click replays it

        var body: some View {
            ZStack(alignment: .topLeading) {
                // Click pulse, centred on the tip.
                Circle().strokeBorder(Theme.accent, lineWidth: 2)
                    .frame(width: 28, height: 28)
                    .scaleEffect(ring ? 1.4 : 0.4).opacity(ring ? 0 : 0.9)
                    .offset(x: AgentCursor.tip.x - 14, y: AgentCursor.tip.y - 14)
                Arrow()
                    .fill(Theme.accent)
                    .overlay(Arrow().stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)))
                    .frame(width: 18, height: 24)
                    .offset(x: AgentCursor.tip.x - 1, y: AgentCursor.tip.y - 1)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                if !model.label.isEmpty {
                    Text(model.label).font(Fonts.bodyStrong).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().fill(Theme.background.opacity(0.85)))
                        .overlay(Capsule().strokeBorder(Theme.borderPanel, lineWidth: 1))
                        .offset(x: 24, y: 18)
                        .fixedSize()
                }
            }
            .frame(width: AgentCursor.size.width, height: AgentCursor.size.height, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
            .onChange(of: model.pulse) { _, _ in
                ring = false
                withAnimation(.easeOut(duration: 0.45)) { ring = true }
            }
        }
    }

    /// Classic pointer shape, tip at (0, 0).
    private struct Arrow: Shape {
        func path(in r: CGRect) -> Path {
            let s = r.width / 18
            var p = Path()
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 0, y: 19 * s))
            p.addLine(to: CGPoint(x: 4.8 * s, y: 14.6 * s))
            p.addLine(to: CGPoint(x: 8.2 * s, y: 22 * s))
            p.addLine(to: CGPoint(x: 11 * s, y: 20.8 * s))
            p.addLine(to: CGPoint(x: 7.8 * s, y: 13.6 * s))
            p.addLine(to: CGPoint(x: 14 * s, y: 13.6 * s))
            p.closeSubpath()
            return p
        }
    }
}
