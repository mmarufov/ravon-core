import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Brand Colors

public extension Color {
    static let ravonRed = Color(red: 1.0, green: 0.19, blue: 0.03)       // #FF3008
    static let ravonDark = Color(red: 0.10, green: 0.10, blue: 0.18)     // #1A1A2E
    static let ravonGray = Color(red: 0.96, green: 0.96, blue: 0.97)     // #F5F5F7
    static let ravonLightGray = Color(red: 0.93, green: 0.93, blue: 0.94)
}

// MARK: - Card Style Modifier

public struct CardStyle: ViewModifier {
    public var padding: CGFloat = 0
    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
    }
}

public extension View {
    func cardStyle(padding: CGFloat = 0) -> some View {
        modifier(CardStyle(padding: padding))
    }
}

// MARK: - Press Scale Button Style

public struct PressableButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Ravon Primary Button

public struct RavonPrimaryButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    public init(_ title: String, isLoading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(title)
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.ravonRed)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: Color.ravonRed.opacity(0.3), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isLoading)
    }
}

// MARK: - Styled Text Field

#if canImport(UIKit)
public struct RavonTextField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool
    var keyboardType: UIKeyboardType
    var contentType: UITextContentType?

    public init(icon: String, placeholder: String, text: Binding<String>, isSecure: Bool = false, keyboardType: UIKeyboardType = .default, contentType: UITextContentType? = nil) {
        self.icon = icon
        self.placeholder = placeholder
        self._text = text
        self.isSecure = isSecure
        self.keyboardType = keyboardType
        self.contentType = contentType
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            if isSecure {
                SecureField(placeholder, text: $text)
                    .textContentType(contentType)
            } else {
                TextField(placeholder, text: $text)
                    .keyboardType(keyboardType)
                    .textContentType(contentType)
                    .textInputAutocapitalization(.never)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
#endif
