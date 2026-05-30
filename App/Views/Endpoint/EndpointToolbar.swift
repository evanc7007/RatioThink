import Security
import SwiftUI

/// Flat, native content-toolbar for the endpoint detail (design §5):
/// `[Profile ▾] │ [Port] [🔐 auth ▾] [🌐 CORS ▾] ─ ● status`.
/// No surrounding rectangle, hairline dividers between logical groups,
/// SF Symbol icons + `Menu` pull-downs that render as `NSPopUpButton`.
///
/// Binds to the store by `endpointID` rather than `Binding<Endpoint>`
/// so each scalar field mutates only itself — review v1 F1 (two
/// sibling subviews snapshotting `endpoint.wrappedValue` independently
/// could otherwise write back stale neighbors on cross-field edits).
struct EndpointToolbar: View {
  @EnvironmentObject private var store: EndpointStore
  let endpointID: UUID

  /// Placeholder profile catalog — replaced with `ProfileStore.entries`
  /// once the XPC pipe is wired in Phase 3.4.
  private let availableProfiles: [String] = ["chat", "creative", "concise"]

  // Local buffer so the Port field commits to the store only on submit
  // or focus loss, not on every keystroke (review v1 F2). Typing "8080"
  // would otherwise transit through 8 → 80 → 808 in the store, each of
  // which could collide with a sibling endpoint and (once the helper
  // start/stop XPC lands) attempt a real `bind()` on an in-progress
  // value.
  @State private var portText: String = ""
  @State private var portError: String?
  @FocusState private var portFocused: Bool

  var body: some View {
    if let endpoint = store.endpoint(id: endpointID) {
      content(endpoint: endpoint)
        .onAppear { portText = String(endpoint.port) }
        .onChange(of: endpoint.port) { _, new in
          // Resync buffer when the live store value changes externally;
          // skip while the field has focus so the user's in-progress
          // input is not clobbered mid-typing.
          if !portFocused { portText = String(new) }
        }
        .onChange(of: endpointID) { _, _ in
          if let e = store.endpoint(id: endpointID) {
            portText = String(e.port)
            portError = nil
          }
        }
    }
  }

  // MARK: - body

  @ViewBuilder
  private func content(endpoint: Endpoint) -> some View {
    HStack(alignment: .top, spacing: 10) {
      profileMenu(current: endpoint.profileID)
      verticalHairline
      portField
      authMenu(current: endpoint.authToken)
      corsMenu(current: endpoint.corsOrigins)
      Spacer(minLength: 8)
      statusBadge(status: endpoint.status)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .background(Color.clear)
    .accessibilityIdentifier("EndpointToolbar")
  }

  // MARK: - groups

  private func profileMenu(current: String) -> some View {
    Menu {
      ForEach(availableProfiles, id: \.self) { id in
        Button(id) { mutate { $0.profileID = id } }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "person.crop.rectangle")
          .foregroundStyle(.secondary)
        Text("Profile: \(current)")
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityIdentifier("EndpointProfile")
  }

  /// Port group renders as a 2-line VStack so the inline error can
  /// appear directly beneath the field without disturbing horizontal
  /// alignment of the other toolbar groups (review v2 F1).
  private var portField: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        Image(systemName: "number")
          .foregroundStyle(.secondary)
        Text("Port:")
          .foregroundStyle(.secondary)
        TextField("Port", text: $portText)
          .textFieldStyle(.plain)
          .frame(width: 56)
          .focused($portFocused)
          .onSubmit(commitPort)
          .onChange(of: portFocused) { _, focused in
            if !focused { commitPort() }
          }
          .onChange(of: portText) { _, _ in
            // Clear stale rejection message as soon as the user edits
            // again so the error doesn't outlive the keystroke.
            if portError != nil { portError = nil }
          }
          .accessibilityIdentifier("EndpointPort")
          .accessibilityValue(portError ?? "")
      }
      if let err = portError {
        Text(err)
          .font(.caption2)
          .foregroundStyle(.red)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("EndpointPortError")
      }
    }
  }

  private func authMenu(current: String?) -> some View {
    Menu {
      Button("No auth") { mutate { $0.authToken = nil } }
      Button("Generate token…") {
        let token = Self.randomToken()
        mutate { $0.authToken = token }
      }
      if current != nil {
        Divider()
        Button("Clear token") { mutate { $0.authToken = nil } }
      }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: current == nil ? "lock.open" : "lock.fill")
          .foregroundStyle(.secondary)
        Text(current == nil ? "auth" : "auth: token")
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityIdentifier("EndpointAuth")
  }

  private func corsMenu(current: [String]) -> some View {
    Menu {
      Button("Same-origin only") { mutate { $0.corsOrigins = [] } }
      Button("Allow localhost") {
        mutate { $0.corsOrigins = ["http://localhost", "http://127.0.0.1"] }
      }
      Button("Allow all (*)") { mutate { $0.corsOrigins = ["*"] } }
    } label: {
      HStack(spacing: 4) {
        Image(systemName: "globe")
          .foregroundStyle(.secondary)
        Text(corsLabel(for: current))
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityIdentifier("EndpointCORS")
  }

  private func statusBadge(status: Endpoint.Status) -> some View {
    HStack(spacing: 6) {
      Image(systemName: status.dotSymbol)
        .font(.system(size: 9))
        .foregroundStyle(status.dotColor)
      Text(status.label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityIdentifier("EndpointStatus")
  }

  private var verticalHairline: some View {
    Rectangle()
      .fill(Color(nsColor: .separatorColor))
      .frame(width: 1, height: 14)
      .accessibilityHidden(true)
  }

  private func corsLabel(for origins: [String]) -> String {
    switch origins {
    case []:      return "CORS: same-origin"
    case ["*"]:   return "CORS: *"
    default:      return "CORS: \(origins.count) origins"
    }
  }

  // MARK: - mutations

  /// Re-read the live row, apply the mutation, write through. Defends
  /// against stale-neighbor clobber when multiple subviews would each
  /// carry their own snapshot of the whole struct (review v1 F1).
  /// Drops + logs when the row has been deleted under the editor —
  /// silent drops were flagged in review v2 F2.
  private func mutate(_ apply: (inout Endpoint) -> Void) {
    guard var e = store.endpoint(id: endpointID) else {
      Log.app.error("endpoint write dropped — id \(self.endpointID.uuidString, privacy: .public) missing from store")
      return
    }
    apply(&e)
    store.upsert(e)
  }

  /// Port commit gate: validates `1...65535`, absence of sibling-port
  /// collision, and that the field is numeric. On rejection the buffer
  /// reverts to the live store value AND `portError` is populated for
  /// visible UI feedback; an `os_log` entry mirrors the reason so the
  /// failure is greppable in Console.app (review v2 F1). Once the
  /// helper start/stop XPC lands this is the same gate that protects
  /// `bind()` from being called on transient digits.
  private func commitPort() {
    guard var e = store.endpoint(id: endpointID) else {
      Log.app.error("port commit dropped — endpoint \(self.endpointID.uuidString, privacy: .public) missing from store")
      return
    }
    let trimmed = portText.trimmingCharacters(in: .whitespaces)
    guard let value = Int(trimmed) else {
      reject(reason: "Port must be a number", detail: "not numeric: \(trimmed)", revertTo: e.port)
      return
    }
    guard (1...65535).contains(value) else {
      reject(reason: "Port must be 1–65535", detail: "out of range: \(value)", revertTo: e.port)
      return
    }
    if let collider = store.endpoints.first(where: { $0.id != endpointID && $0.port == value }) {
      reject(
        reason: "Port \(value) in use by '\(collider.name)'",
        detail: "collision with \(collider.id.uuidString) (\(collider.name))",
        revertTo: e.port
      )
      return
    }
    portError = nil
    if value != e.port {
      e.port = value
      store.upsert(e)
    }
  }

  private func reject(reason: String, detail: String, revertTo: Int) {
    portError = reason
    portText = String(revertTo)
    Log.app.info("port commit rejected: \(detail, privacy: .public)")
  }

  /// CSPRNG-backed 128-bit hex bearer token. `SecRandomCopyBytes` is
  /// the only source we accept here — the previous `randomElement()`
  /// loop drew from Swift's default (non-cryptographic) RNG, and once
  /// `EndpointStore` gains TOML persistence (Phase 5) these tokens
  /// land on disk and gate real `Authorization: Bearer` checks
  /// (review v2 F3).
  private static func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess,
                 "SecRandomCopyBytes failed (status=\(status)) — refusing to mint a weak bearer token")
    return bytes.map { String(format: "%02x", $0) }.joined()
  }
}
