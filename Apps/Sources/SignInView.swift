import SwiftUI

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("serverURL") private var serverURL = APIClient.defaultServerURL
    @AppStorage("lastHandle") private var lastHandle = ""
    @State private var handle = ""
    @State private var errorMessage: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Totem")
                .font(.largeTitle.bold())
            TextField("Handle", text: $handle)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            Button(busy ? "Signing in…" : "Sign In") {
                Task { await signIn() }
            }
            .disabled(handle.count < 3 || busy)
            TextField("Server", text: $serverURL)
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
                .frame(maxWidth: 240)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                #endif
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .onAppear {
            if handle.isEmpty { handle = lastHandle }
        }
    }

    private func signIn() async {
        busy = true
        defer { busy = false }
        do {
            try await model.signIn(handle: handle, serverURL: serverURL)
        } catch {
            errorMessage = "Couldn't sign in. Is the server running?"
        }
    }
}
