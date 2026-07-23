import SwiftUI

enum LadleTheme {
    static let paperHex = "#FBFAF7"
    static let fieldHex = "#F1EEE8"
    static let inkHex = "#1F1D1A"
    static let paprikaHex = "#B44B24"
    static let reviewHex = "#F6ECD9"
    static let successHex = "#3D7A44"

    static let paper = Color("Paper")
    static let field = Color("Field")
    static let ink = Color("Ink")
    static let paprika = Color("Paprika")
    static let review = Color("Review")
    static let success = Color("Success")

    enum Spacing {
        static let compact: CGFloat = 8
        static let regular: CGFloat = 16
        static let generous: CGFloat = 24
        static let cooking: CGFloat = 32
    }

    enum Corner {
        static let control: CGFloat = 12
        static let card: CGFloat = 16
        static let sheet: CGFloat = 34
    }
}
