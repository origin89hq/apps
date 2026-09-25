import Origin89UI
import SetupKit
import SwiftUI

/// The signed-in user's sites, and the controllers this phone is paired with
/// that can be linked to one. A link names a controller generation for the
/// account; it grants no access to the controller, which pairing alone does.
struct SitesView: View {
  let cloud: CloudClient
  /// The generations of the pairings this account sees on this phone.
  let generations: () -> [ControllerGeneration]
  /// Presents AuthKit when the cloud wants a fresh sign-in.
  let authenticate: (URL, String) async throws(AccountError) -> URL

  @State private var sites: [Site]?
  @State private var paired: [ControllerGeneration] = []
  @State private var failure: CloudError?
  @State private var busy = false
  @State private var newSiteName = ""
  @State private var creatingSite = false
  @State private var linking: ControllerGeneration?

  var body: some View {
    Form {
      if let failure {
        Section { Origin89Notice(failure.message, tone: .alarm) }
      }
      if let sites {
        controllers(sites)
        siteList(sites)
      } else {
        Section { ProgressView() }
      }
    }
    .navigationTitle("Sites")
    .navigationBarTitleDisplayMode(.inline)
    .disabled(busy)
    .task { await reload() }
    .refreshable { await reload() }
    .alert("New site", isPresented: $creatingSite) {
      TextField("Name", text: $newSiteName)
      Button("Create") { Task { await createSite() } }
        .disabled(DisplayName(newSiteName) == nil)
      Button("Cancel", role: .cancel) {}
    }
    .sheet(item: $linking) { generation in
      LinkControllerView(
        generation: generation,
        sites: (sites ?? []).filter { $0.role == .owner },
        link: { name, site in await link(generation, named: name, to: site) })
    }
  }

  @ViewBuilder private func controllers(_ sites: [Site]) -> some View {
    Section {
      if paired.isEmpty {
        Text("No controller is paired with this phone yet.").foregroundStyle(.secondary)
      }
      ForEach(paired, id: \.self) { generation in
        let site = sites.first { $0.links(generation) }
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(
              site?.controllers.first { $0.generation == generation }?.name
                ?? generation.defaultName)
            Text(site.map { "Linked to \($0.name)" } ?? "Not linked")
              .font(.footnote).foregroundStyle(.secondary)
          }
          Spacer()
          if site == nil {
            Button("Link") { linking = generation }
              .disabled(!sites.contains { $0.role == .owner })
          }
        }
      }
    } header: {
      Text("Paired with this phone")
    } footer: {
      Text(
        "Linking sends only the controller's ID and reset count to your account, never its setup code or this phone's key."
      )
    }
  }

  @ViewBuilder private func siteList(_ sites: [Site]) -> some View {
    Section {
      ForEach(sites) { site in
        VStack(alignment: .leading, spacing: 2) {
          Text(site.name)
          Text(Self.summary(of: site)).font(.footnote).foregroundStyle(.secondary)
        }
      }
      Button("New site") {
        newSiteName = ""
        creatingSite = true
      }
    } header: {
      Text("Sites")
    }
  }

  private static func summary(of site: Site) -> String {
    let role = site.role == .owner ? "Owner" : "Admin"
    return switch site.controllers.count {
    case 0: "\(role) · no controllers"
    case 1: "\(role) · 1 controller"
    case let count: "\(role) · \(count) controllers"
    }
  }

  private func reload() async {
    paired = generations()
    do {
      sites = try await cloud.sites()
      failure = nil
    } catch {
      failure = error
    }
  }

  private func createSite() async {
    guard let name = DisplayName(newSiteName) else { return }
    busy = true
    defer { busy = false }
    do {
      _ = try await cloud.createSite(named: name)
      await reload()
    } catch {
      failure = error
    }
  }

  /// Nil on success; otherwise the failure, which the link sheet shows.
  private func link(
    _ generation: ControllerGeneration, named name: DisplayName, to site: Site.ID
  ) async -> CloudError? {
    do {
      _ = try await cloud.link(generation, named: name, to: site, authenticate: authenticate)
    } catch {
      return error
    }
    await reload()
    return nil
  }
}

/// Choose a site the user owns and a name, then link.
private struct LinkControllerView: View {
  let generation: ControllerGeneration
  let sites: [Site]
  let link: (DisplayName, Site.ID) async -> CloudError?

  @State private var name: String
  @State private var site: Site.ID?
  @State private var failure: CloudError?
  @State private var linking = false
  @Environment(\.dismiss) private var dismiss

  init(
    generation: ControllerGeneration, sites: [Site],
    link: @escaping (DisplayName, Site.ID) async -> CloudError?
  ) {
    self.generation = generation
    self.sites = sites
    self.link = link
    _name = State(initialValue: generation.defaultName)
    _site = State(initialValue: sites.count == 1 ? sites.first?.id : nil)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Name") { TextField("Name", text: $name) }
        Section("Site") {
          Picker("Site", selection: $site) {
            Text("Choose a site").tag(Site.ID?.none)
            ForEach(sites) { Text($0.name).tag(Site.ID?.some($0.id)) }
          }
        }
        if let failure {
          Section { Origin89Notice(failure.message, tone: .alarm) }
        }
      }
      .navigationTitle("Link controller")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          if linking {
            ProgressView()
          } else {
            Button("Link") { Task { await submit() } }
              .disabled(site == nil || DisplayName(name) == nil)
          }
        }
      }
      .disabled(linking)
    }
  }

  private func submit() async {
    guard let site, let name = DisplayName(name) else { return }
    linking = true
    defer { linking = false }
    if let error = await link(name, site) {
      failure = error == .account(.cancelled) ? nil : error
    } else {
      dismiss()
    }
  }
}

extension ControllerGeneration {
  /// A name until the person gives one: the start of the `device_id`.
  fileprivate var defaultName: String { "Controller \(deviceID.prefix(8))" }
}
