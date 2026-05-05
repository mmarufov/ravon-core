#if canImport(UIKit)
import SwiftUI

public struct RavonSignUpView: View {
    @ObservedObject var vm: AuthFlowViewModel

    @State private var fullName: String = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var acceptedTerms: Bool = false
    @State private var isSubmitting: Bool = false
    @FocusState private var focus: Field?

    private enum Field { case name, email, password }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("Создать аккаунт")
                        .font(.largeTitle.weight(.bold))
                    Text("Это займёт меньше минуты")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                if let banner = vm.inlineBanner {
                    bannerView(banner)
                }

                if let err = vm.inlineError {
                    AuthErrorBanner(error: err)
                }

                VStack(spacing: 12) {
                    RavonTextField(
                        icon: "person",
                        placeholder: "Ваше имя",
                        text: $fullName,
                        contentType: .name
                    )
                    .focused($focus, equals: .name)

                    RavonTextField(
                        icon: "envelope",
                        placeholder: "Почта",
                        text: $email,
                        keyboardType: .emailAddress,
                        contentType: .emailAddress
                    )
                    .focused($focus, equals: .email)

                    RavonTextField(
                        icon: "lock",
                        placeholder: "Пароль (минимум 8 символов)",
                        text: $password,
                        isSecure: true,
                        contentType: .newPassword
                    )
                    .focused($focus, equals: .password)

                    RavonPasswordStrengthMeter(password: password)
                        .padding(.top, 4)
                }

                Toggle(isOn: $acceptedTerms) {
                    Text("Я принимаю условия использования и политику конфиденциальности")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(SwitchToggleStyle(tint: .ravonRed))

                RavonPrimaryButton("Зарегистрироваться", isLoading: isSubmitting) {
                    Task { await submit() }
                }
                .disabled(!canSubmit || isSubmitting)
                .opacity(canSubmit ? 1 : 0.55)

                signInFooter
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var canSubmit: Bool {
        !fullName.trimmingCharacters(in: .whitespaces).isEmpty
            && EmailValidator.isLikelyValid(email)
            && password.count >= 8
            && acceptedTerms
    }

    private var signInFooter: some View {
        HStack(spacing: 4) {
            Text("Уже есть аккаунт?")
                .foregroundStyle(.secondary)
            Button {
                vm.presentSignIn(prefillEmail: email.isEmpty ? nil : email)
            } label: {
                Text("Войти")
                    .foregroundStyle(Color.ravonRed)
                    .fontWeight(.medium)
            }
        }
        .font(.footnote)
        .padding(.top, 12)
    }

    private func bannerView(_ banner: AuthFlowViewModel.BannerCTA) -> some View {
        HStack {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.ravonRed)
            Text(banner.text)
                .font(.footnote)
            Spacer()
            switch banner.action {
            case .signInWith(let prefill):
                Button("Войти") {
                    vm.presentSignIn(prefillEmail: prefill)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ravonRed)
            }
        }
        .padding(12)
        .background(Color.ravonRed.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func submit() async {
        guard canSubmit, !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        _ = await vm.performSignUp(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            password: password,
            fullName: fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
#endif
