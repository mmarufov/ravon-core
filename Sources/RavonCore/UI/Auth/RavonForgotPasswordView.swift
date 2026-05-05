#if canImport(UIKit)
import SwiftUI

public struct RavonForgotPasswordView: View {
    @ObservedObject var vm: AuthFlowViewModel

    @State private var email: String = ""
    @State private var isSubmitting: Bool = false
    @FocusState private var focused: Bool

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Сброс пароля")
                        .font(.largeTitle.weight(.bold))
                    Text("Введите почту от аккаунта — мы пришлём 6-значный код для сброса пароля.")
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                if let err = vm.inlineError {
                    AuthErrorBanner(error: err)
                }

                RavonTextField(
                    icon: "envelope",
                    placeholder: "Почта",
                    text: $email,
                    keyboardType: .emailAddress,
                    contentType: .emailAddress
                )
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { Task { await submit() } }

                RavonPrimaryButton("Отправить код", isLoading: isSubmitting) {
                    Task { await submit() }
                }
                .disabled(!EmailValidator.isLikelyValid(email) || isSubmitting)
                .opacity(EmailValidator.isLikelyValid(email) ? 1 : 0.55)

                Button {
                    vm.presentSignIn(prefillEmail: email.isEmpty ? nil : email)
                } label: {
                    Text("Назад ко входу")
                        .font(.footnote)
                        .foregroundStyle(Color.ravonRed)
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear {
            if !vm.prefilledEmail.isEmpty { email = vm.prefilledEmail }
            focused = email.isEmpty
        }
    }

    private func submit() async {
        guard EmailValidator.isLikelyValid(email), !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        _ = await vm.performRequestRecovery(email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
#endif
