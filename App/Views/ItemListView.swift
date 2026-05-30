import SwiftUI

/// Col 2 — items inside the selected sidebar section. v1 has no item model
/// wired yet (lands in 3.3 chats / 4.x endpoints); placeholder rows here keep
/// the column shape testable and let `View > Hide List` exercise the binding.
struct ItemListView: View {
  let section: SidebarSection?
  @Binding var selectedItemID: UUID?

  var body: some View {
    Group {
      switch section {
      case .chats:
        ChatListView(selectedItemID: $selectedItemID)
      case .apiEndpoints:
        EndpointListView(selectedItemID: $selectedItemID)
      case .none:
        Text("Select a section")
          .foregroundStyle(.secondary)
      }
    }
    .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
  }
}
