import SwiftUI

/// Col 2 rows for the *API Endpoints* sidebar section. Per design §5:
/// name + URL + status dot. Empty state shows an inline *Create endpoint*
/// CTA. Selection binds back into `WindowState.selectedItemID` via the
/// caller (`ItemListView`).
struct EndpointListView: View {
  @EnvironmentObject private var store: EndpointStore
  @Binding var selectedItemID: UUID?

  var body: some View {
    Group {
      if store.endpoints.isEmpty {
        emptyState
      } else {
        List(selection: $selectedItemID) {
          ForEach(store.endpoints) { endpoint in
            EndpointRow(endpoint: endpoint)
              .tag(Optional(endpoint.id))
          }
        }
        .listStyle(.sidebar)
      }
    }
    .accessibilityIdentifier("EndpointList")
  }

  /// Top-aligned per design §5 ("API endpoints empty → inline Create
  /// endpoint row"). The trailing `Spacer` pins the row to the top
  /// rather than vertically centering it.
  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("No endpoints yet")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text("Expose a profile as an OpenAI-compatible HTTP endpoint.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        selectedItemID = store.createEndpoint().id
      } label: {
        Label("Create Endpoint", systemImage: "plus")
      }
      .controlSize(.regular)
      .accessibilityIdentifier("CreateEndpoint")
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

private struct EndpointRow: View {
  let endpoint: Endpoint

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: endpoint.status.dotSymbol)
        .font(.system(size: 8))
        .foregroundStyle(endpoint.status.dotColor)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(endpoint.name)
          .font(.body)
          .lineLimit(1)
        Text(endpoint.baseURL)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(endpoint.name), \(endpoint.status.label), \(endpoint.baseURL)")
  }
}
