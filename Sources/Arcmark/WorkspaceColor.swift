import AppKit

enum WorkspaceColorId: String, Codable, CaseIterable {
    case ember
    case ruby
    case coral
    case tangerine
    case moss
    case ocean
    case indigo
    case graphite

    var name: String {
        switch self {
        case .ember: return "Ember"
        case .ruby: return "Ruby"
        case .coral: return "Coral"
        case .tangerine: return "Tangerine"
        case .moss: return "Moss"
        case .ocean: return "Ocean"
        case .indigo: return "Indigo"
        case .graphite: return "Graphite"
        }
    }

    var color: NSColor {
        switch self {
        case .ember: return NSColor(calibratedRed: 0.66, green: 0.17, blue: 0.19, alpha: 1.0)
        case .ruby: return NSColor(calibratedRed: 0.72, green: 0.20, blue: 0.29, alpha: 1.0)
        case .coral: return NSColor(calibratedRed: 0.78, green: 0.29, blue: 0.28, alpha: 1.0)
        case .tangerine: return NSColor(calibratedRed: 0.87, green: 0.47, blue: 0.20, alpha: 1.0)
        case .moss: return NSColor(calibratedRed: 0.28, green: 0.45, blue: 0.26, alpha: 1.0)
        case .ocean: return NSColor(calibratedRed: 0.18, green: 0.43, blue: 0.61, alpha: 1.0)
        case .indigo: return NSColor(calibratedRed: 0.29, green: 0.30, blue: 0.55, alpha: 1.0)
        case .graphite: return NSColor(calibratedRed: 0.23, green: 0.23, blue: 0.24, alpha: 1.0)
        }
    }

    var backgroundColor: NSColor {
        color.withAlphaComponent(0.92)
    }

    var textColor: NSColor {
        NSColor.white
    }
}

extension WorkspaceColorId {
    static func defaultColor() -> WorkspaceColorId { .ember }
}
