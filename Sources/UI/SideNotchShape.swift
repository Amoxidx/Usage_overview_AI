import SwiftUI

/// Pill welded to the left screen edge with inverse flare corners (Codenotch SideNotchShape).
/// Canonical path is written for the right edge, then mirrored for `.left`.
struct SideNotchShape: Shape {
    var curlRadius: CGFloat = NotchLayout.curlRadius
    var cornerRadius: CGFloat = NotchLayout.cornerRadius

    func path(in rect: CGRect) -> Path {
        let depth = rect.width
        let length = rect.height
        let canonical = canonicalPath(in: CGRect(x: 0, y: 0, width: depth, height: length))
        // Mirror for left edge (bezel at minX after transform).
        let mirrored = canonical.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: depth, ty: 0))
        return mirrored.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    private func canonicalPath(in rect: CGRect) -> Path {
        let flare = curlRadius
        let wanted = max(0, min(cornerRadius, rect.width / 2))
        let curl = max(0, min(flare, rect.height / 2, rect.width - wanted))
        let corner = max(0, min(wanted, (rect.height - 2 * curl) / 2))
        let bodyTop = rect.minY + curl
        let bodyBottom = rect.maxY - curl

        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        if curl > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - curl, y: rect.minY),
                radius: curl,
                startAngle: .degrees(0), endAngle: .degrees(90),
                clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: rect.minX + corner, y: bodyTop))
        path.addArc(
            center: CGPoint(x: rect.minX + corner, y: bodyTop + corner),
            radius: corner,
            startAngle: .degrees(270), endAngle: .degrees(180),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.minX, y: bodyBottom - corner))
        path.addArc(
            center: CGPoint(x: rect.minX + corner, y: bodyBottom - corner),
            radius: corner,
            startAngle: .degrees(180), endAngle: .degrees(90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: rect.maxX - curl, y: bodyBottom))
        if curl > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - curl, y: rect.maxY),
                radius: curl,
                startAngle: .degrees(270), endAngle: .degrees(360),
                clockwise: false
            )
        }
        path.closeSubpath()
        return path
    }
}
