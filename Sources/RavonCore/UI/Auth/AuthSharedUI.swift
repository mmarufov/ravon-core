#if canImport(UIKit)
import SwiftUI

/// Inline error banner used by every auth screen. Renders the localized
/// description of an `AuthError` with brand styling.
struct AuthErrorBanner: View {
    let error: AuthError
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(error.errorDescription ?? "")
                .foregroundStyle(.white)
                .font(.footnote)
            Spacer()
        }
        .padding(12)
        .background(Color.ravonRed.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Email format check — RFC 5322 is overkill, this catches typos like
/// missing @ or trailing whitespace which is what the form needs.
public enum EmailValidator {
    public static func isLikelyValid(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5, trimmed.contains("@"), trimmed.contains(".") else { return false }
        let parts = trimmed.split(separator: "@")
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[1].contains(".") else { return false }
        return true
    }
}
#endif
