import Foundation

/// Server-computed ETA + escalation-ladder hint, kept tight for realtime broadcast.
///
/// The fields map directly to the matching columns on `orders` so a single decode
/// path serves both the initial `fetchOrderEta` call and the realtime `OrderEtaEvent`
/// payload. `delayWarningActive` is derived: `expected_action_by` is in the past
/// but `courier_delay_explained_at` is not yet stamped.
public struct OrderEta: Codable, Sendable, Equatable {
    public let orderId: UUID
    public let etaMinutes: Int?
    public let expectedActionBy: Date?
    public let courierDelayReasonCode: String?
    public let courierDelayExplainedAt: Date?
    public let courierNoShowWarnedAt: Date?
    public let courierNoShowEscalatedAt: Date?
    public let status: OrderStatus

    public init(
        orderId: UUID,
        etaMinutes: Int?,
        expectedActionBy: Date?,
        courierDelayReasonCode: String?,
        courierDelayExplainedAt: Date?,
        courierNoShowWarnedAt: Date?,
        courierNoShowEscalatedAt: Date?,
        status: OrderStatus
    ) {
        self.orderId = orderId
        self.etaMinutes = etaMinutes
        self.expectedActionBy = expectedActionBy
        self.courierDelayReasonCode = courierDelayReasonCode
        self.courierDelayExplainedAt = courierDelayExplainedAt
        self.courierNoShowWarnedAt = courierNoShowWarnedAt
        self.courierNoShowEscalatedAt = courierNoShowEscalatedAt
        self.status = status
    }

    /// True when the SLA has been breached AND the courier hasn't explained yet.
    /// Drives consumer-side "Курьер задерживается" banner.
    public var delayWarningActive: Bool {
        guard let due = expectedActionBy else { return false }
        if courierDelayExplainedAt != nil { return false }
        return due < Date()
    }

    /// True when the system has posted the "we're trying to reach the courier"
    /// system message in chat (T+2 ladder step).
    public var escalated: Bool { courierNoShowEscalatedAt != nil }

    enum CodingKeys: String, CodingKey {
        case orderId = "id"
        case etaMinutes = "eta_minutes"
        case expectedActionBy = "expected_action_by"
        case courierDelayReasonCode = "courier_delay_reason_code"
        case courierDelayExplainedAt = "courier_delay_explained_at"
        case courierNoShowWarnedAt = "courier_no_show_warned_at"
        case courierNoShowEscalatedAt = "courier_no_show_escalated_at"
        case status
    }
}
