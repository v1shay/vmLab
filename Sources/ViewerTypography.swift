import AppKit
import CoreText
import SwiftUI

enum ViewerTypography {
    enum Face: String {
        case regular = "Regular"
        case medium = "Medium"
        case semibold = "SemiBold"
    }

    private static let registeredNames: [Face: String] = {
        var names: [Face: String] = [:]
        for face in [Face.regular, .medium, .semibold] {
            guard let url = Bundle.main.url(forResource: "IoskeleyMono-\(face.rawValue)",
                                           withExtension: "ttf", subdirectory: "Fonts"),
                  let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                    as? [CTFontDescriptor],
                  let descriptor = descriptors.first,
                  let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
            else { continue }
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) ||
                NSFont(name: name, size: 13) != nil {
                names[face] = name
            }
        }
        return names
    }()

    private static let hasGeist: Bool = {
        if let url = Bundle.main.url(forResource: "Geist-SemiBold", withExtension: "otf", subdirectory: "Fonts") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return NSFont(name: "Geist-SemiBold", size: 13) != nil
    }()

    static var nativeFontName: String { registeredNames[.regular] ?? "Menlo-Regular" }

    static let geistHeading = geist(size: 22, relativeTo: .title2)

    static func geist(size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        hasGeist ? .custom("Geist-SemiBold", size: size, relativeTo: style)
            : .system(size: size, weight: .semibold)
    }

    static func font(_ face: Face, size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        guard let name = registeredNames[face] else {
            let weight: Font.Weight
            switch face {
            case .regular: weight = .regular
            case .medium: weight = .medium
            case .semibold: weight = .semibold
            }
            return .system(size: size, weight: weight)
        }
        return .custom(name, size: size, relativeTo: style)
    }
}
