import Foundation

/// How the courier completes the hand-off.
/// - `handToMe`: courier enters the consumer's `delivery_verification_code`.
/// - `leaveAtDoor`: courier uploads a photo to the `delivery-proofs` bucket.
public enum DeliveryMode: String, Codable, CaseIterable, Sendable {
    case handToMe    = "hand_to_me"
    case leaveAtDoor = "leave_at_door"

    public var localizedDisplayName: String {
        switch self {
        case .handToMe:    return "Передать в руки"
        case .leaveAtDoor: return "Оставить у двери"
        }
    }

    /// Whether the courier RPC requires a delivery code on `courier_deliver_order`.
    public var requiresDeliveryCode: Bool { self == .handToMe }

    /// Whether the courier RPC requires a photo on `courier_deliver_order`.
    public var requiresProofImage: Bool { self == .leaveAtDoor }
}
