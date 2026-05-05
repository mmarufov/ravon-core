#if canImport(UIKit)
import SwiftUI

public struct RavonNewPasswordView: View {
    public enum Mode: Equatable {
        case afterRecovery
        case changeFromSettings
    }

    @ObservedObject var vm: AuthFlowViewModel
    let mode: Mode
    let onDone: () -> Void

    @State private var currentPassword: String = ""
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var isSubmitting: Bool = false
    @State private var localError: String?

    public init(vm: AuthFlowViewModel, mode: Mode, onDone: @escaping () -> Void) {
        self.vm = vm
        self.mode = mode
        self.onDone = onDone
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                    Text(subtitle)
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                if let err = vm.inlineError {
                    AuthErrorBanner(error: err)
                } else if let s = localError {
                    AuthErrorBanner(error: .unknown(s))
                }

                if mode == .changeFromSettings {
                    RavonTextField(
                        icon: "lock",
                        placeholder: "Текущий пароль",
                        text: $currentPassword,
                        isSecure: true,
                        contentType: .password
                    )
                }

                RavonTextField(
                    icon: "lock.rotation",
                    placeholder: "Новый пароль",
                    text: $newPassword,
                    isSecure: true,
                    contentType: .newPassword
                )

                RavonPasswordStrengthMeter(password: newPassword)

                RavonTextField(
                    icon: "lock.rotation",
                    placeholder: "Повторите новый пароль",
                    text: $confirmPassword,
                    isSecure: true,
                    contentType: .newPassword
                )

                RavonPrimaryButton(actionTitle, isLoading: isSubmitting) {
                    Task { await submit() }
                }
                .disabled(!canSubmit || isSubmitting)
                .opacity(canSubmit ? 1 : 0.55)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var title: String {
        mode == .afterRecovery ? "Новый пароль" : "Изменить пароль"
    }
    private var subtitle: String {
        mode == .afterRecovery
            ? "Придумайте новый пароль для вашего аккаунта."
            : "Введите текущий пароль и новый пароль."
    }
    private var actionTitle: String {
        mode == .afterRecovery ? "Сохранить и войти" : "Сохранить"
    }
    private var canSubmit: Bool {
        guard newPassword.count >= 8, newPassword == confirmPassword else { return false }
        if mode == .changeFromSettings, currentPassword.isEmpty { return false }
        return true
    }

    private func submit() async {
        guard canSubmit, !isSubmitting else { return }
        localError = nil
        if newPassword != confirmPassword {
            localError = "Пароли не совпадают"
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }

        switch mode {
        case .afterRecovery:
            let ok = await vm.performSetNewPassword(newPassword)
            if ok { onDone() }
        case .changeFromSettings:
            do {
                try await AuthService.shared.changePassword(
                    current: currentPassword,
                    new: newPassword
                )
                onDone()
            } catch let e as AuthError {
                localError = e.errorDescription
            } catch {
                localError = AuthError.from(error).errorDescription
            }
        }
    }
}
#endif
