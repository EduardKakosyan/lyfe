import SwiftUI

/// First launch: where the backend is, and the lyfe password.
public struct SignInView: View {
    @Bindable var model: AppModel
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field {
        case server, password
    }

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Poster.tight("LYFE", by: -5))
                    .font(.system(size: 96, weight: .heavy))
                    .padding(.top, 24)
                Text("Sign in to your server").posterLabel()
                    .padding(.bottom, 22)

                field("Server") {
                    TextField("", text: $model.serverAddress, prompt: Text("name.tailnet.ts.net:8444"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                        #endif
                        .submitLabel(.next)
                        .focused($focus, equals: .server)
                        .onSubmit { focus = .password }
                }
                field("Password") {
                    SecureField("", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit(submit)
                }

                if let problem = model.signInProblem {
                    HStack(alignment: .top, spacing: 8) {
                        PosterSquare(state: .striped, size: 12).padding(.top, 1)
                        Text(problem).posterLabel()
                    }
                    .padding(.top, 14)
                }
                Spacer()
            }
            .padding(.horizontal, Poster.margin)

            Button(action: submit) {
                HStack {
                    Text(model.isSigningIn ? "SIGNING IN" : "SIGN IN")
                        .font(.system(size: 22, weight: .heavy))
                        .tracking(-0.6)
                    Spacer()
                    Text("→").font(.system(size: 30, weight: .heavy))
                }
                .padding(.horizontal, Poster.margin)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .foregroundStyle(Poster.paper)
                .background(Poster.ink.ignoresSafeArea(edges: .bottom))
            }
            .buttonStyle(.plain)
            .disabled(model.isSigningIn)
        }
        .foregroundStyle(Poster.ink)
        .tint(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        .onAppear {
            focus = model.serverAddress.isEmpty ? .server : .password
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).posterLabel()
            content()
                .font(.system(size: 20, weight: .bold))
                .textFieldStyle(.plain)
                .padding(.vertical, 6)
            PosterRule()
        }
        .padding(.top, 12)
    }

    private func submit() {
        let attempt = password
        Task {
            await model.signIn(password: attempt)
            if model.phase == .signedIn {
                password = ""
            }
        }
    }
}
