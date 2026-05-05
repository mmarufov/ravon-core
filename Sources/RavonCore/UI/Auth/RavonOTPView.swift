#if canImport(UIKit)
import SwiftUI
import UIKit

public enum OTPMode: Equatable {
    case signup
    case recovery

    var resendKey: String {
        switch self {
        case .signup:   return "signup"
        case .recovery: return "recovery"
        }
    }

    var title: String {
        switch self {
        case .signup:   return "Подтверждение почты"
        case .recovery: return "Восстановление пароля"
        }
    }

    var subtitle: String {
        "Мы отправили 6-значный код на"
    }
}

public struct RavonOTPView: View {
    @ObservedObject var vm: AuthFlowViewModel
    let email: String
    let mode: OTPMode
    let onSuccess: () -> Void

    @State private var code: String = ""
    @State private var isVerifying: Bool = false
    @State private var isResending: Bool = false
    @State private var cooldown: TimeInterval = 0
    @State private var shake: Int = 0
    @FocusState private var focused: Bool
    @State private var timer: Timer?

    private let codeLength = 6

    public var body: some View {
        VStack(spacing: 24) {
            header
            errorBanner
            codeField
            verifyButton
            resendRow
            footer
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear {
            focused = true
            tickCooldown()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in tickCooldown() }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
        .onChange(of: code) { _, new in
            // Strip non-digits, cap to 6.
            let digits = new.filter(\.isNumber)
            let trimmed = String(digits.prefix(codeLength))
            if trimmed != new { code = trimmed }
            if trimmed.count == codeLength {
                Task { await verify() }
            }
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        VStack(spacing: 8) {
            Text(mode.title)
                .font(.title2.weight(.bold))
            Text(mode.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(email)
                .font(.subheadline.weight(.medium))
            Button {
                vm.go(to: mode == .signup ? .signUp : .forgotEmail)
            } label: {
                Text("Изменить email")
                    .font(.footnote)
                    .foregroundStyle(Color.ravonRed)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = vm.inlineError {
            Text(err.errorDescription ?? "")
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.ravonRed.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var codeField: some View {
        ZStack {
            // Hidden TextField backing the visible cells. Wraps `.oneTimeCode`
            // so iOS auto-fills the SMS/email code from the system bar.
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .opacity(0.02)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .accessibilityLabel("Код подтверждения")

            HStack(spacing: 8) {
                ForEach(0..<codeLength, id: \.self) { i in
                    digitCell(at: i)
                }
            }
            .allowsHitTesting(false)
        }
        .modifier(ShakeEffect(animatableData: CGFloat(shake)))
        .onTapGesture { focused = true }
    }

    private func digitCell(at index: Int) -> some View {
        let chars = Array(code)
        let ch: String = index < chars.count ? String(chars[index]) : ""
        let isCursor = index == chars.count
        return Text(ch.isEmpty ? (isCursor && focused ? "_" : "") : ch)
            .font(.system(size: 24, weight: .semibold, design: .rounded))
            .frame(width: 48, height: 60)
            .background(Color(.systemGray6))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        ch.isEmpty ? Color.clear : Color.ravonRed.opacity(0.4),
                        lineWidth: 1.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var verifyButton: some View {
        RavonPrimaryButton("Подтвердить", isLoading: isVerifying) {
            Task { await verify() }
        }
        .disabled(code.count != codeLength || isVerifying)
        .opacity(code.count == codeLength ? 1 : 0.55)
    }

    private var resendRow: some View {
        HStack(spacing: 4) {
            Text("Не получили код?")
                .foregroundStyle(.secondary)
            Button {
                Task { await resend() }
            } label: {
                if isResending {
                    ProgressView().controlSize(.small)
                } else if cooldown > 0 {
                    Text("Отправить снова через \(Int(ceil(cooldown))) сек")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Отправить снова")
                        .foregroundStyle(Color.ravonRed)
                        .fontWeight(.medium)
                }
            }
            .disabled(cooldown > 0 || isResending)
        }
        .font(.footnote)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("Код действует 10 минут. Проверьте папку «Спам», если письмо не пришло.")
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    // MARK: - Actions

    private func verify() async {
        guard !isVerifying, code.count == codeLength else { return }
        isVerifying = true
        defer { isVerifying = false }

        let ok: Bool
        switch mode {
        case .signup:
            ok = await vm.performVerifySignUp(email: email, code: code)
        case .recovery:
            ok = await vm.performVerifyRecovery(email: email, code: code)
        }
        if ok {
            onSuccess()
        } else {
            withAnimation(.default) { shake += 1 }
            code = ""
            focused = true
        }
    }

    private func resend() async {
        isResending = true
        defer { isResending = false }
        switch mode {
        case .signup:    await vm.performResendSignUp(email: email)
        case .recovery:  await vm.performResendRecovery(email: email)
        }
        tickCooldown()
    }

    private func tickCooldown() {
        cooldown = vm.resendCooldownRemaining(email: email, step: mode.resendKey)
    }
}

private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        let amount: CGFloat = 8
        let shakes: CGFloat = 3
        let translation = amount * sin(animatableData * .pi * shakes)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}
#endif
