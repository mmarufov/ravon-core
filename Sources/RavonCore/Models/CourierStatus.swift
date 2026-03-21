import Foundation

public enum CourierStatus: String, Codable, CaseIterable, Sendable {
    case online
    case offline
    case delivering

    public var displayName: String {
        switch self {
        case .online:     return "На линии"
        case .offline:    return "Не на линии"
        case .delivering: return "Доставляет"
        }
    }
}
