import SwiftUI
import WheelhouseKit
import WheelhouseUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Palette for the editor

enum EditorColors {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> PlatformColor {
        #if canImport(UIKit)
        UIColor { t in
            let hex = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        #else
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        #endif
    }
    static let key = dynamic(0x0B7A75, 0x5EEAD4)
    static let string = dynamic(0x1B7F3B, 0x7DDC9A)
    static let number = dynamic(0x8250DF, 0xC4A1FF)
    static let keyword = dynamic(0xB45309, 0xFBBF24)
    static let anchor = dynamic(0x0060C7, 0x409CFF)
    static let marker = dynamic(0x6C6C70, 0x8E8E93)
    static let error = dynamic(0xCC1F2B, 0xFF6B63)
    static let warning = dynamic(0xB45309, 0xFFB340)

    static var secondaryLabel: PlatformColor {
        #if canImport(UIKit)
        .secondaryLabel
        #else
        .secondaryLabelColor
        #endif
    }

    static func color(for kind: YAMLToken.Kind) -> PlatformColor {
        switch kind {
        case .key: key
        case .string: string
        case .number: number
        case .keyword: keyword
        case .comment: secondaryLabel
        case .anchor: anchor
        case .punctuation: secondaryLabel
        case .marker: marker
        }
    }
}
