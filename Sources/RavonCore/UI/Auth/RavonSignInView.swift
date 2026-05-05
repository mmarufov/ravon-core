#if canImport(UIKit)
import SwiftUI

public struct RavonSignInView: View {
    @ObservedObject var vm: AuthFlowViewModel
    let onSignedIn: () -> Void

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isSubmitting: Bool = false
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("Вход в Ravon")
                        .font(.largeTitle.weight(.bold))
                    Text("С возвращением!")
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
                        icon: "envelope",
                        placeholder: "Почта",
                        text: $email,
                        keyboardType: .emailAddress,
                        contentType: .emailAddress
                    )
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }

                    RavonTextField(
                        icon: "lock",
                        placeholder: "Пароль",
                        text: $password,
                        isSecure: true,
                        contentType: .password
                    )
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await submit() } }

                    HStack {
                        Spacer()
                        Button {
                            vm.presentForgotPassword(prefillEmail: email.isEmpty ? nil : email)
                        } label: {
                            Text("Забыли пароль?")
                                .font(.footnote)
                                .foregroundStyle(Color.ravonRed)
                        }
                    }
                }

                RavonPrimaryButton("Войти", isLoading: isSubmitting) {
                    Task { await submit() }
                }
                .disabled(!canSubmit || isSubmitting)
                .opacity(canSubmit ? 1 : 0.55)

                signUpFooter
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear {
            if !vm.prefilledEmail.isEmpty { email = vm.prefilledEmail }
        }
    }

    private var canSubmit: Bool {
        EmailValidator.isLikelyValid(email) && password.count >= 1
    }

    private var signUpFooter: some View {
        HStack(spacing: 4) {
            Text("Нет аккаунта?")
                .foregroundStyle(.secondary)
            Button {
                vm.presentSignUp()
            } label: {
                Text("Создать аккаунт")
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
                    email = prefill
                    focus = .password
                    vm.dismissBanner()
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
        let ok = await vm.performSignIn(email: email, password: password)
        if ok { onSignedIn() }
    }
}
#endif
