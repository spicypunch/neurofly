import AppKit
import SpriteKit

/// The small set of colors shared by the experiment window and the desktop pet.
/// Keeping these in one place makes the UI readable without scattering magic NSColor values.
enum NeuroFlyStyle {
    static let ink = NSColor(calibratedWhite: 0.96, alpha: 1)
    static let mutedInk = NSColor(calibratedWhite: 0.70, alpha: 1)
    static let dimInk = NSColor(calibratedWhite: 0.48, alpha: 1)
    static let canvas = NSColor(calibratedRed: 0.075, green: 0.095, blue: 0.085, alpha: 1)
    static let canvasRaised = NSColor(calibratedRed: 0.105, green: 0.135, blue: 0.120, alpha: 1)
    static let canvasLine = NSColor(calibratedRed: 0.27, green: 0.37, blue: 0.30, alpha: 0.28)
    static let cream = NSColor(calibratedRed: 0.96, green: 0.88, blue: 0.69, alpha: 1)
    static let creamSoft = NSColor(calibratedRed: 0.96, green: 0.88, blue: 0.69, alpha: 0.16)
    static let mint = NSColor(calibratedRed: 0.46, green: 0.83, blue: 0.69, alpha: 1)
    static let mintSoft = NSColor(calibratedRed: 0.46, green: 0.83, blue: 0.69, alpha: 0.14)
    static let coral = NSColor(calibratedRed: 0.95, green: 0.44, blue: 0.36, alpha: 1)
    static let orange = NSColor(calibratedRed: 1.0, green: 0.63, blue: 0.24, alpha: 1)
    static let plum = NSColor(calibratedRed: 0.45, green: 0.32, blue: 0.49, alpha: 1)

    static let skCanvas = SKColor(calibratedRed: 0.075, green: 0.095, blue: 0.085, alpha: 1)
    static let skCanvasRaised = SKColor(calibratedRed: 0.105, green: 0.135, blue: 0.120, alpha: 1)
    static let skCanvasLine = SKColor(calibratedRed: 0.27, green: 0.37, blue: 0.30, alpha: 0.28)
    static let skCream = SKColor(calibratedRed: 0.96, green: 0.88, blue: 0.69, alpha: 1)
    static let skMint = SKColor(calibratedRed: 0.46, green: 0.83, blue: 0.69, alpha: 1)
    static let skCoral = SKColor(calibratedRed: 0.95, green: 0.44, blue: 0.36, alpha: 1)
    static let skOrange = SKColor(calibratedRed: 1.0, green: 0.63, blue: 0.24, alpha: 1)
}

enum ArenaTool: String, CaseIterable {
    case food
    case shadow
    case touch

    var title: String {
        switch self {
        case .food: return "먹이 놓기"
        case .shadow: return "그림자"
        case .touch: return "건드리기"
        }
    }

    var shortTitle: String {
        switch self {
        case .food: return "먹이"
        case .shadow: return "그림자"
        case .touch: return "건드리기"
        }
    }

    var hint: String {
        switch self {
        case .food: return "아레나를 클릭해 먹이를 놓으세요"
        case .shadow: return "아레나를 클릭해 다가오는 그림자를 만드세요"
        case .touch: return "초파리를 클릭하면 접촉 자극을 보냅니다"
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xff) / 255
        let green = CGFloat((hex >> 8) & 0xff) / 255
        let blue = CGFloat(hex & 0xff) / 255
        self.init(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension String {
    /// A compact number formatter for the small status chips in the inspector.
    static func neuroFlyCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "ko_KR")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func neuroFlyRate(_ value: Float) -> String {
        String(format: "%.2f Hz", value)
    }
}
