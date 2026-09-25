import AuthenticationServices
import Origin89UI
import SetupKit
import SwiftUI

/// Optional sign-in. Setup never asks for it: pairing and the controller's
/// network work the same signed in or out.
struct AccountView: View {
  let account: Account

  @State private var failure: AccountError?
  @State private var confirmingSignOut = false
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        switch account.status {
        case .signedOut, .signingIn: signedOut
        case .signedIn(let user): signedIn(user)
        }
        if let failure {
          Section { Origin89Notice(failure.message, tone: .alarm) }
        }
      }
      .navigationTitle("Account")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
    .confirmationDialog(
      "Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible
    ) {
      Button("Sign out", role: .destructive, action: signOut)
    } message: {
      Text(
        "Controllers paired while signed in stay on this phone and come back when you sign in again."
      )
    }
  }

  @ViewBuilder private var signedOut: some View {
    Section {
      if account.sessionEnded {
        Origin89Notice("Your session ended. Sign in again to use your account.", tone: .info)
      }
      Text("An account is optional. Pairing and setting up a controller work without one.")
      if !account.isAvailable { Origin89Notice(AccountError.notConfigured.message, tone: .info) }
      Button(action: signIn) {
        if account.status == .signingIn {
          HStack(spacing: 12) {
            ProgressView()
            Text("Signing in…")
          }
        } else {
          Text("Sign in")
        }
      }
      .disabled(account.status == .signingIn || !account.isAvailable)
    } footer: {
      Text("Sign in with Apple, Google, a passkey or a code sent by email.")
    }
  }

  @ViewBuilder private func signedIn(_ user: AccountUser) -> some View {
    Section {
      if let name = [user.firstName, user.lastName].compactMap(\.self).joined(separator: " ")
        .nonEmpty
      {
        Text(name)
      }
      Text(user.email).foregroundStyle(.secondary)
    } header: {
      Text("Signed in")
    }
    Section {
      Button("Sign out", role: .destructive) { confirmingSignOut = true }
    } footer: {
      Text(
        "Controllers paired while signed in show only in this account. Controllers paired while signed out show in every account."
      )
    }
  }

  private func signIn() {
    failure = nil
    Task {
      do throws(AccountError) {
        try await account.signIn { url, scheme throws(AccountError) in
          do {
            return try await webAuthenticationSession.authenticate(
              using: url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
          } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw .cancelled
          } catch {
            throw .unavailable
          }
        }
      } catch {
        if error != .cancelled { failure = error }
      }
    }
  }

  private func signOut() {
    failure = nil
    do { try account.signOut() } catch { failure = error }
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
