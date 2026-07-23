import SwiftUI

enum LadleTypography {
    static let display = Font.system(
        size: 44,
        weight: .medium,
        design: .serif
    )
    static let title = Font.system(
        size: 32,
        weight: .medium,
        design: .serif
    )
    static let recipeTitle = Font.system(
        size: 21,
        weight: .semibold,
        design: .serif
    )
    static let section = Font.system(
        size: 19,
        weight: .semibold,
        design: .serif
    )
    static let body = Font.system(size: 17, weight: .regular)
    static let bodyStrong = Font.system(size: 17, weight: .semibold)
    static let metadata = Font.system(size: 13, weight: .medium)
    static let eyebrow = Font.system(size: 12, weight: .bold)
}
