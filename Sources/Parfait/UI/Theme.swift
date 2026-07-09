import SwiftUI

/// Parfait palette — layered like the dessert: cream, raspberry, honey, blueberry, mint.
enum Theme {
    static let cream = Color(red: 1.00, green: 0.976, blue: 0.949)          // #FFF9F2 surfaces
    static let creamDeep = Color(red: 0.984, green: 0.945, blue: 0.894)     // #FBF1E4 cards
    static let raspberry = Color(red: 0.878, green: 0.224, blue: 0.420)     // #E0396B primary
    static let honey = Color(red: 0.949, green: 0.663, blue: 0.231)         // #F2A93B secondary
    static let blueberry = Color(red: 0.353, green: 0.416, blue: 0.812)     // #5A6ACF chat/links
    static let mint = Color(red: 0.247, green: 0.698, blue: 0.498)          // #3FB27F recording
    static let cocoa = Color(red: 0.263, green: 0.196, blue: 0.169)         // #43322B text

    static let cornerRadius: CGFloat = 16

    /// Card background that stays airy in light mode and warm-dark in dark mode.
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.145, green: 0.125, blue: 0.114) : cream
    }
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.196, green: 0.169, blue: 0.153) : creamDeep
    }
    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.96, green: 0.94, blue: 0.92) : cocoa
    }
}

extension Font {
    static func parfait(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
