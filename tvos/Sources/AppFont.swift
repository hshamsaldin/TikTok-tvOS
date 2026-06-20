import UIKit
import SwiftUI

// Bundled Inter font, with a safe fallback to the system font (San Francisco) if
// it ever fails to register — so the UI can never end up font-less.

extension UIFont {
    static func app(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont(name: interName(weight), size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

extension Font {
    static func app(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> Font {
        .custom(interName(weight), size: size)
    }
}

private func interName(_ weight: UIFont.Weight) -> String {
    switch weight {
    case .bold, .heavy, .black: return "Inter-Bold"
    case .semibold:             return "Inter-SemiBold"
    case .medium:               return "Inter-Medium"
    default:                    return "Inter-Regular"
    }
}
