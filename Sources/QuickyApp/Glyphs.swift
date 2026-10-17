import SwiftUI

/// Stroke icons on Hugeicons' 24-unit grid, drawn at any size with a constant 1.5 pt stroke.
enum Glyph {
    case question, loading, tick, alert

    fileprivate func path() -> Path {
        var p = Path()
        switch self {
        case .question:
            // help-circle's "?" without its circle, scaled up to fill the grid
            p.move(to: CGPoint(x: 8.5, y: 8.5))
            p.addCurve(to: CGPoint(x: 12, y: 5), control1: CGPoint(x: 8.5, y: 6.57), control2: CGPoint(x: 10.07, y: 5))
            p.addCurve(to: CGPoint(x: 15.5, y: 8.5), control1: CGPoint(x: 13.93, y: 5), control2: CGPoint(x: 15.5, y: 6.57))
            p.addCurve(to: CGPoint(x: 14.95, y: 10.39), control1: CGPoint(x: 15.5, y: 9.2), control2: CGPoint(x: 15.3, y: 9.85))
            p.addCurve(to: CGPoint(x: 12, y: 15.5), control1: CGPoint(x: 13.9, y: 12.02), control2: CGPoint(x: 12, y: 13.57))
            p.addLine(to: CGPoint(x: 12, y: 16))
            p.move(to: CGPoint(x: 11.99, y: 19.5))
            p.addLine(to: CGPoint(x: 12.01, y: 19.5))
        case .loading:
            for (a, b) in [((12, 3), (12, 6)), ((12, 18), (12, 21)), ((21, 12), (18, 12)), ((6, 12), (3, 12)),
                           ((18.36, 5.64), (16.24, 7.76)), ((7.76, 16.24), (5.64, 18.36)),
                           ((18.36, 18.36), (16.24, 16.24)), ((7.76, 7.76), (5.64, 5.64))] {
                p.move(to: CGPoint(x: a.0, y: a.1))
                p.addLine(to: CGPoint(x: b.0, y: b.1))
            }
        case .tick:
            p.move(to: CGPoint(x: 5, y: 14))
            p.addLine(to: CGPoint(x: 8.5, y: 17.5))
            p.addLine(to: CGPoint(x: 19, y: 6.5))
        case .alert:
            p.addEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))
            p.move(to: CGPoint(x: 12, y: 7.5))
            p.addLine(to: CGPoint(x: 12, y: 12.5))
            p.move(to: CGPoint(x: 11.99, y: 16))
            p.addLine(to: CGPoint(x: 12.01, y: 16))
        }
        return p
    }
}

private struct GlyphShape: Shape {
    let glyph: Glyph
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        return glyph.path().applying(CGAffineTransform(scaleX: s, y: s))
    }
}

struct GlyphView: View {
    let glyph: Glyph
    let size: CGFloat
    let color: Color

    var body: some View {
        GlyphShape(glyph: glyph)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// loading-03 turning once per 800 ms; static under Reduce Motion.
struct Spinner: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            GlyphView(glyph: .loading, size: size, color: Theme.loader)
        } else {
            TimelineView(.animation) { context in
                let turns = context.date.timeIntervalSinceReferenceDate / 0.8
                GlyphView(glyph: .loading, size: size, color: Theme.loader)
                    .rotationEffect(.degrees((turns - turns.rounded(.down)) * 360))
            }
        }
    }
}
