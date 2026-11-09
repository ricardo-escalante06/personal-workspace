import AuthenticationServices
import CryptoKit
import SwiftUI
import WorkspaceUI

/// Bottom of the sidebar: Sign in with Apple, or the signed-in state.
struct AccountFooter: View {
    @Environment(AppModel.self) private var model
    @State private var nonce = Nonce.make()

    var body: some View {
        VStack(alignment: .leading, spacing: WSSpace.s) {
            Divider()
            switch model.syncStatus {
            case .localOnly:
                Label("Local only — add Supabase keys to sync", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(WSColor.textSecondary)
            case .signedOut:
                SignInWithAppleButton(.signIn) { request in
                    nonce = Nonce.make()
                    request.requestedScopes = []
                    request.nonce = Nonce.sha256(nonce)
                } onCompletion: { result in
                    handle(result)
                }
                .signInWithAppleButtonStyle(.white)
                .frame(height: 32)
            default:
                HStack {
                    Label("Signed in", systemImage: "person.crop.circle")
                        .font(.caption)
                        .foregroundStyle(WSColor.textSecondary)
                    Spacer()
                    Button("Sign out") { Task { await model.signOut() } }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, WSSpace.m)
        .padding(.bottom, WSSpace.m)
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard
                let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let token = String(data: tokenData, encoding: .utf8)
            else {
                model.errorMessage = "Apple didn't return an identity token."
                return
            }
            let raw = nonce
            Task { await model.signInWithApple(idToken: token, nonce: raw) }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                model.errorMessage = "Sign in with Apple failed: \(error.localizedDescription)"
            }
        }
    }
}

struct SyncStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Task { await model.syncNow() }
        } label: {
            switch model.syncStatus {
            case .localOnly: Label("Local", systemImage: "internaldrive")
            case .signedOut: Label("Signed out", systemImage: "icloud.slash")
            case .idle: Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            case .syncing: Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
            case .synced: Label(model.pendingChanges > 0 ? "\(model.pendingChanges) pending" : "Synced", systemImage: "checkmark.icloud")
            case .failed: Label("Sync failed", systemImage: "exclamationmark.icloud")
            }
        }
        .help(helpText)
        .disabled(model.userId == nil)
    }

    private var helpText: String {
        switch model.syncStatus {
        case .failed(let message): message
        case .synced(let date): "Last synced \(date.formatted(date: .omitted, time: .shortened))"
        default: "Sync now (⇧⌘R)"
        }
    }
}

/// Nonce for Sign in with Apple: the SHA-256 goes to Apple, the raw value to Supabase.
enum Nonce {
    static func make(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator)! })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
