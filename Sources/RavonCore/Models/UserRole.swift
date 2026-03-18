import Foundation

public enum UserRole: String, Codable, CaseIterable, Sendable {
    case consumer
    case courier
    case merchant

    public var displayName: String {
        switch self {
        case .consumer: return "Заказчик"
        case .courier:  return "Курьер"
        case .merchant: return "Ресторан"
        }
    }
}
