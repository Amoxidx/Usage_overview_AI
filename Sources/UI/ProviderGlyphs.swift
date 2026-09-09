import SwiftUI

/// Vector marks traced from the Codenotch design frame.
struct ProviderGlyphView: View {
    let id: ProviderID
    var size: CGFloat = Design.glyphSize

    private var outline: [[CGPoint]] {
        switch id {
        case .claude: return GlyphOutlines.claude
        case .codex:  return GlyphOutlines.openai
        case .grok:   return GlyphOutlines.cube
        }
    }

    private var opticalScale: CGFloat {
        switch id {
        case .claude: return 0.97
        case .codex:  return 0.94
        case .grok:   return 1.0
        }
    }

    var body: some View {
        GlyphShape(outline: outline)
            .fill(style: FillStyle(eoFill: true))
            .scaleEffect(opticalScale)
            .frame(width: size, height: size)
            .foregroundStyle(Palette.textPrimary)
    }
}

/// Traced outline scaled into the view's bounds; even-odd keeps knot/cube holes open.
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
