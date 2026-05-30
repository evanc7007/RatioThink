import SwiftUI

/// *Settings → API* — summary of every endpoint configured in the
/// main window's *API Endpoints* sidebar. Editing happens there
/// (`EndpointDetailView`); this pane is the at-a-glance view of which
/// profiles are exposed and on which ports, plus a launch-on-boot
/// toggle stub mirrored from the General tab convention.
struct APISettingsTab: View {
  @EnvironmentObject private var store: EndpointStore

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SettingsSectionHeader(title: "Endpoints")
      Text("OpenAI-compatible HTTP endpoints are managed in the main window's *API Endpoints* sidebar. This pane lists what is currently configured.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if store.endpoints.isEmpty {
        ContentUnavailableView {
          Label("No endpoints configured", systemImage: "network")
        } description: {
          Text("Open the main window → API Endpoints → Create Endpoint.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Table(store.endpoints) {
          TableColumn("Name") { row in
            Text(row.name)
          }
          TableColumn("Profile") { row in
            Text(row.profileID).monospaced().foregroundStyle(.secondary)
          }
          TableColumn("Port") { row in
            Text("\(row.port)").monospacedDigit()
          }
          .width(min: 60, ideal: 70)
        }
        .frame(minHeight: 200)
      }
    }
    .padding(20)
  }
}
