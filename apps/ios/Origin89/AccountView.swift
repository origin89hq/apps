import AuthenticationServices
import Origin89UI
import SetupKit
import SwiftUI

/// Optional sign-in. Setup never asks for it: pairing and the controller's
/// network work the same signed in or out.
struct AccountView: View {
  let account: Account
  /// Nil in a build without a cloud.
  let cloud: CloudClient?
  let pairings: any AccountPairingStore
  /// The generations of the pairings this account sees on this phone.
  let generations: () throws -> [ControllerGeneration]

  @State private var failure: String?
  @State private var confirmingSignOut = false
  @State private var confirmingDeletion = false
  @State private var deleting = false
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
          Section { Origin89Notice(failure, tone: .alarm) }
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
    .confirmationDialog(
      "Delete your account?", isPresented: $confirmingDeletion, titleVisibility: .visible
    ) {
      Button("Delete account, keep pairings", role: .destructive) { delete(.keep) }
      Button("Delete account and pairings", role: .destructive) { delete(.forget) }
    } message: {
      Text(
        "Your Origin89 account, its sites and memberships are deleted. Controllers are not reset. This phone can keep the pairings made in this account as signed-out pairings, or remove them."
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
    if let cloud {
      Section {
        NavigationLink("Sites") {
          SitesView(cloud: cloud, generations: generations, authenticate: authenticate)
        }
      } footer: {
        Text("Link the controllers paired with this phone to a site in your account.")
      }
    }
    Section {
      Button("Sign out", role: .destructive) { confirmingSignOut = true }
        .disabled(deleting)
    } footer: {
      Text(
        "Controllers paired while signed in show only in this account. Controllers paired while signed out show in every account."
      )
    }
    Section {
      Button(role: .destructive) {
        confirmingDeletion = true
      } label: {
        if deleting {
          HStack(spacing: 12) {
            ProgressView()
            Text("Deleting…")
          }
        } else {
          Text("Delete account")
        }
      }
      .disabled(deleting || cloud == nil)
    } footer: {
      if cloud == nil {
        Text("This build has no Origin89 cloud, so the account cannot be deleted from it.")
      } else {
        Text("You may be asked to sign in again first.")
      }
    }
  }

  private func signIn() {
    failure = nil
    Task {
      do throws(AccountError) {
        try await account.signIn(using: authenticate)
      } catch {
        if error != .cancelled { failure = error.message }
      }
    }
  }

  private func signOut() {
    failure = nil
    do { try account.signOut() } catch { failure = error.message }
  }

  private func delete(_ kept: DeletedPairings) {
    guard let cloud else { return }
    failure = nil
    deleting = true
    Task {
      defer { deleting = false }
      do throws(CloudError) {
        // Signed out once it returns, which closes this sheet.
        _ = try await cloud.deleteAccount(
          pairings: kept, store: pairings, authenticate: authenticate)
      } catch {
        if error != .account(.cancelled) { failure = error.message }
      }
    }
  }

  /// The AuthKit page in an ephemeral web session, returning its redirect.
  private func authenticate(_ url: URL, _ scheme: String) async throws(AccountError) -> URL {
    do {
      return try await webAuthenticationSession.authenticate(
        using: url, callbackURLScheme: scheme, preferredBrowserSession: .ephemeral)
    } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
      throw .cancelled
    } catch {
      throw .unavailable
    }
  }
}

extension String {
  fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
