import SwiftUI

/// Vector marks: Anthropic spark, OpenAI knot, Grok favicon swirl.
struct ProviderGlyphView: View {
    let id: ProviderID
    var size: CGFloat = NotchLayout.glyphSize

    var body: some View {
        Group {
            switch id {
            case .claude:
                GlyphShape(outline: GlyphOutlines.claude)
                    .fill(style: FillStyle(eoFill: true))
                    .scaleEffect(0.98)
            case .codex:
                GlyphShape(outline: GlyphOutlines.openai)
                    .fill(style: FillStyle(eoFill: true))
                    .scaleEffect(0.96)
            case .grok:
                GlyphShape(outline: GrokGlyphOutline.points)
                    .fill(style: FillStyle(eoFill: true))
                    .scaleEffect(0.95)
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(Color.white)
        .shadow(color: .black.opacity(0.35), radius: 0.6, x: 0, y: 0.5)
    }
}

struct GlyphShape: Shape {
    let outline: [[CGPoint]]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for loop in outline {
            guard let first = loop.first else { continue }
            path.move(to: point(first, in: rect))
            for p in loop.dropFirst() {
                path.addLine(to: point(p, in: rect))
            }
            path.closeSubpath()
        }
        return path
    }

    private func point(_ p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }
}
