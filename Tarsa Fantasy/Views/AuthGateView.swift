import SwiftUI

struct AuthGateView: View {
    @Environment(AppState.self) private var app

    enum Mode: String, CaseIterable, Identifiable {
        case signIn, signUp
        var id: String { rawValue }
        var label: String { self == .signIn ? "Sign in" : "Sign up" }
        var cta: String   { self == .signIn ? "Sign in" : "Create account" }
        var subtitle: String {
            self == .signIn
                ? "Welcome back. Pick up where you left off."
                : "Pick a username. Run your league."
        }
    }

    @State private var mode: Mode = .signIn
    @State private var username: String = ""
    @State private var password: String = ""

    var body: some View {
        ZStack(alignment: .top) {
            FFColor.bg.ignoresSafeArea()
            FFGlow().ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: FFSpace.xxxl) {
                    headline
                    modeSwitcher
                    form
                    cta
                    Spacer(minLength: 40)
                }
                .padding(.horizontal, FFSpace.xxl)
                .padding(.top, 80)
                .padding(.bottom, 40)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("FANTASY FOOTBALL").ffEyebrow(color: FFColor.accent)
            Text(mode == .signIn ? "Welcome\nback." : "Build your\nleague.")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(FFColor.textPrimary)
                .lineSpacing(-4)
            Text(mode.subtitle)
                .font(.ffBody)
                .foregroundStyle(FFColor.textSecondary)
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases) { m in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { mode = m }
                } label: {
                    Text(m.label)
                        .font(.ffHeadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(mode == m ? FFColor.bg : FFColor.textSecondary)
                        .background(
                            mode == m ? FFColor.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: FFRadius.s)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s + 4))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.s + 4)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private var form: some View {
        VStack(spacing: FFSpace.m) {
            field("Username") {
                TextField("", text: $username, prompt: Text("yourname").foregroundColor(FFColor.textTertiary))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
            }
            field("Password") {
                SecureField("", text: $password, prompt: Text("at least 6 characters").foregroundColor(FFColor.textTertiary))
                    .textContentType(mode == .signUp ? .newPassword : .password)
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).ffEyebrow()
            content()
                .font(.ffBody)
                .foregroundStyle(FFColor.textPrimary)
                .padding(.horizontal, FFSpace.l)
                .padding(.vertical, 14)
                .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.s))
                .overlay(
                    RoundedRectangle(cornerRadius: FFRadius.s)
                        .strokeBorder(FFColor.border, lineWidth: 1)
                )
        }
    }

    private var cta: some View {
        VStack(spacing: FFSpace.s) {
            if let err = app.authError {
                Text(err)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.negative)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await submit() }
            } label: {
                Group {
                    if app.isAuthInFlight {
                        ProgressView().tint(FFColor.bg)
                    } else {
                        Text(mode.cta)
                    }
                }
                .ffPrimaryButton(disabled: submitDisabled)
            }
            .disabled(submitDisabled)
        }
    }

    private var submitDisabled: Bool {
        app.isAuthInFlight
            || username.trimmingCharacters(in: .whitespaces).count < 3
            || password.count < 6
    }

    private func submit() async {
        let u = username.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .signIn: await app.signIn(username: u, password: password)
        case .signUp: await app.signUp(username: u, password: password)
        }
    }
}
