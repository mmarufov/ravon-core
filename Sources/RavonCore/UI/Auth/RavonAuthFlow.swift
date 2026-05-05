#if canImport(UIKit)
import SwiftUI

/// Shared auth flow consumed by all 3 apps. Pass the app's role and an
/// `onSignedIn` callback — RavonCore handles every screen, transition, and
/// error state internally.
///
/// ```swift
/// RavonAuthFlow(role: .consumer) {
///     // navigate to main app
/// }
/// ```
public struct RavonAuthFlow: View {
    @StateObject private var vm: AuthFlowViewModel
    private let onSignedIn: () -> Void
    private let onCancel: (() -> Void)?

    public init(
        role: UserRole,
        onSignedIn: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        _vm = StateObject(wrappedValue: AuthFlowViewModel(role: role))
        self.onSignedIn = onSignedIn
        self.onCancel = onCancel
    }

    public var body: some View {
        Group {
            switch vm.step {
            case .signIn:
                RavonSignInView(vm: vm, onSignedIn: onSignedIn)
            case .signUp:
                RavonSignUpView(vm: vm)
            case .otpSignUp(let email):
                RavonOTPView(
                    vm: vm,
                    email: email,
                    mode: .signup,
                    onSuccess: { onSignedIn() }
                )
            case .forgotEmail:
                RavonForgotPasswordView(vm: vm)
            case .otpRecovery(let email):
                RavonOTPView(
                    vm: vm,
                    email: email,
                    mode: .recovery,
                    onSuccess: { /* vm advances itself */ }
                )
            case .newPasswordAfterRecovery:
                RavonNewPasswordView(vm: vm, mode: .afterRecovery, onDone: onSignedIn)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: vm.step)
    }
}
#endif
