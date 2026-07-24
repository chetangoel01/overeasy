import SwiftUI

enum LadleTheme {
    static let plumHex = "#493943"
    static let paperHex = "#FAF6EF"
    static let oatHex = "#F1ECE3"
    static let inkHex = "#30272D"
    static let brickHex = "#AD503D"
    static let celeryHex = "#BEC9AE"
    static let ubeHex = "#DDD5DF"
    static let mutedInkHex = "#72676D"

    static let plum = Color("Plum")
    static let paper = Color("Paper")
    static let oat = Color("Oat")
    static let ink = Color("Ink")
    static let brick = Color("Brick")
    static let celery = Color("Celery")
    static let ube = Color("Ube")
    static let mutedInk = Color("MutedInk")

    static let field = oat
    static let paprika = brick
    static let review = ube
    static let success = celery

    enum Spacing {
        static let tight: CGFloat = 4
        static let compact: CGFloat = 8
        static let medium: CGFloat = 12
        static let regular: CGFloat = 16
        static let generous: CGFloat = 24
        static let cooking: CGFloat = 32
    }

    enum Corner {
        static let control: CGFloat = 15
        static let card: CGFloat = 20
        static let sheet: CGFloat = 34
    }
}
