#if canImport(UIKit)
import SwiftUI

public struct RavonPasswordStrengthMeter: View {
    public let password: String
    public init(password: String) { self.password = password }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(at: i))
                        .frame(height: 4)
                }
            }
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if !password.isEmpty {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var strength: Strength { Strength.evaluate(password) }
    private var label: String {
        switch strength {
        case .empty:  return ""
        case .weak:   return "Слабый"
        case .medium: return "Средний"
        case .strong: return "Сильный"
        }
    }
    private var hint: String {
        if password.count < 8 { return "минимум 8 символов" }
        switch strength {
        case .weak:   return "добавьте цифру или символ"
        case .medium: return "добавьте символ для надёжности"
        default:      return ""
        }
    }
    private func barColor(at i: Int) -> Color {
        let n = strength.barsLit
        if i < n {
            switch strength {
            case .weak:   return .red
            case .medium: return .orange
            case .strong: return .green
            default:      return Color(.systemGray5)
            }
        }
        return Color(.systemGray5)
    }

    public enum Strength: Equatable {
        case empty, weak, medium, strong
        var barsLit: Int {
            switch self {
            case .empty:  return 0
            case .weak:   return 1
            case .medium: return 2
            case .strong: return 3
            }
        }
        public static func evaluate(_ p: String) -> Strength {
            if p.isEmpty { return .empty }
            if p.count < 8 { return .weak }

            let hasLower = p.contains(where: { $0.isLetter && $0.isLowercase })
            let hasUpper = p.contains(where: { $0.isLetter && $0.isUppercase })
            let hasDigit = p.contains(where: \.isNumber)
            let hasSymbol = p.contains(where: { !$0.isLetter && !$0.isNumber })

            let classes = [hasLower, hasUpper, hasDigit, hasSymbol].filter { $0 }.count
            switch classes {
            case 0, 1: return .weak
            case 2:    return p.count >= 10 ? .medium : .weak
            case 3:    return p.count >= 12 ? .strong : .medium
            default:   return .strong
            }
        }
    }
}
#endif
