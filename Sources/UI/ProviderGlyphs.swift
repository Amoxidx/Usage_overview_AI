import SwiftUI

/// Vector marks: Anthropic spark + OpenAI knot from traced outlines; Grok = xAI-style X.
struct ProviderGlyphView: View {
    let id: ProviderID
    var size: CGFloat = Design.glyphSize

    var body: some View {
        Group {
            switch id {
            case .claude:
                GlyphShape(outline: GlyphOutlines.claude)
                    .fill(style: FillStyle(eoFill: true))
                    .scaleEffect(0.97)
            case .codex:
                GlyphShape(outline: GlyphOutlines.openai)
                    .fill(style: FillStyle(eoFill: true))
                    .scaleEffect(0.94)
            case .grok:
                GrokXMark()
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(Palette.textPrimary)
    }
}

/// xAI / Grok mark: thick rounded X (not the Perplexity cube from the Codenotch screenshot).
private struct GrokXMark: View {
    var body: some View {
        Canvas { context, size in
            let inset = size.width * 0.18
            let thickness = size.width * 0.18
            let stroke = StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round)

            var a = Path()
            a.move(to: CGPoint(x: inset, y: inset))
            a.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset))
            context.stroke(a, with: .foreground, style: stroke)

            var b = Path()
            b.move(to: CGPoint(x: size.width - inset, y: inset))
            b.addLine(to: CGPoint(x: inset, y: size.height - inset))
            context.stroke(b, with: .foreground, style: stroke)
        }
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
