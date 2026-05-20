import Foundation

enum RootTab: String, CaseIterable, Identifiable {
    case research
    case portfolio
    case privacy
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .research: "Research"
        case .portfolio: "Portfolio"
        case .privacy: "Privacy"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .research: "magnifyingglass"
        case .portfolio: "chart.line.uptrend.xyaxis"
        case .privacy: "lock.shield"
        case .settings: "gearshape"
        }
    }
}
