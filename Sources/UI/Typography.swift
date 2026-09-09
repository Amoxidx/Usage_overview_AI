import SwiftUI

enum Typography {
    static let percent = Font.system(size: Design.fontSize(capPixels: 27), weight: .semibold)
    static let cardTitle = Font.system(size: Design.fontSize(capPixels: 26), weight: .semibold)
    static let cardBody = Font.system(size: Design.fontSize(capPixels: 18), weight: .regular)
}
