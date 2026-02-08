import AppKit

enum WorkspaceColorId: String, Codable {
    case ember
    case ruby
    case coral
    case tangerine
    case moss
    case ocean
    case indigo
    case graphite
    case settingsBackground

    var name: String {
        switch self {
        case .ember: return "Blush"
        case .ruby: return "Apricot"
        case .coral: return "Butter"
        case .tangerine: return "Leaf"
        case .moss: return "Mint"
        case .ocean: return "Sky"
        case .indigo: return "Periwinkle"
        case .graphite: return "Lavender"
        case .settingsBackground: return "Settings"
        }
    }

    var color: NSColor {
        switch self {
        case .ember: return NSColor(calibratedRed: 1.00, green: 0.635, blue: 0.635, alpha: 1.0) // #FFA2A2
        case .ruby: return NSColor(calibratedRed: 1.00, green: 0.722, blue: 0.416, alpha: 1.0) // #FFB86A
        case .coral: return NSColor(calibratedRed: 1.00, green: 0.941, blue: 0.522, alpha: 1.0) // #FFF085
        case .tangerine: return NSColor(calibratedRed: 0.847, green: 0.976, blue: 0.600, alpha: 1.0) // #D8F999
        case .moss: return NSColor(calibratedRed: 0.369, green: 0.914, blue: 0.710, alpha: 1.0) // #5EE9B5
        case .ocean: return NSColor(calibratedRed: 0.325, green: 0.918, blue: 0.992, alpha: 1.0) // #53EAFD
        case .indigo: return NSColor(calibratedRed: 0.639, green: 0.702, blue: 1.00, alpha: 1.0) // #A3B3FF
        case .graphite: return NSColor(calibratedRed: 0.855, green: 0.698, blue: 1.00, alpha: 1.0) // #DAB2FF
        case .settingsBackground: return NSColor(calibratedRed: 0.898, green: 0.906, blue: 0.922, alpha: 1.0) // #E5E7EB
        }
    }

    var backgroundColor: NSColor {
        if self == .settingsBackground {
            return color
        }
        return color.withAlphaComponent(0.92)
    }

    var textColor: NSColor {
        NSColor.white
    }
}

extension WorkspaceColorId {
    static var allCases: [WorkspaceColorId] {
        [.ember, .ruby, .coral, .tangerine, .moss, .ocean, .indigo, .graphite]
    }

    static func defaultColor() -> WorkspaceColorId { .ember }

    static func randomColor() -> WorkspaceColorId {
        WorkspaceColorId.allCases.randomElement() ?? .defaultColor()
    }
}
