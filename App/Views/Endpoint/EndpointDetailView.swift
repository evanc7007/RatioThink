import SwiftUI

/// Col 3 — endpoint configuration form + curl-example pane + live
/// request-log tail. The flat content toolbar (`EndpointToolbar`) sits
/// directly on `NSColor.windowBackgroundColor` per design §5; below it
/// the body is split into config / curl / log panes via a `VSplitView`
/// so the log can be resized without a hard-coded height.
///
/// Field-level writes route through `EndpointStore` keyed by id rather
/// than via a `Binding<Endpoint>` propagated to subviews; this avoids
/// stale-neighbor clobber on cross-field edits (review v1 F1).
struct EndpointDetailView: View {
  @EnvironmentObject private var store: EndpointStore
  let endpointID: UUID

  var body: some View {
    if let endpoint = store.endpoint(id: endpointID) {
      content(endpoint: endpoint)
    } else {
      ContentUnavailableView(
        "Endpoint not found",
        systemImage: "questionmark.circle",
        description: Text("This endpoint may have been removed.")
      )
    }
  }

  // MARK: - body

  @ViewBuilder
  private func content(endpoint: Endpoint) -> some View {
    VStack(spacing: 0) {
      EndpointToolbar(endpointID: endpointID)
      Divider()
      VSplitView {
        configAndCurl(endpoint: endpoint)
          .frame(minHeight: 240)
        RequestLogPane(endpoint: endpoint)
          .frame(minHeight: 120)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("EndpointDetail")
  }

  private func configAndCurl(endpoint: Endpoint) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        nameField()
        urlSection(endpoint: endpoint)
        curlSection(endpoint: endpoint)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func nameField() -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Name")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextField("Endpoint name", text: scalarBinding(\.name, fallback: ""))
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("EndpointName")
    }
  }

  private func urlSection(endpoint: Endpoint) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("URL")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Text(endpoint.baseURL)
          .textSelection(.enabled)
          .font(.system(.body, design: .monospaced))
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(endpoint.baseURL, forType: .string)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .controlSize(.small)
      }
    }
  }

  private func curlSection(endpoint: Endpoint) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("curl example")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(curlSnippet(for: endpoint), forType: .string)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .controlSize(.small)
      }
      Text(curlSnippet(for: endpoint))
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(Color(nsColor: .textBackgroundColor))
        )
        .accessibilityIdentifier("EndpointCurl")
    }
  }

  // MARK: - helpers

  /// Build a scalar `Binding` rooted at the live store entry. Getter
  /// reads through every access (no captured snapshot); setter re-reads
  /// the row by id, mutates only the targeted key path, and writes
  /// back. Sibling scalar bindings against the same endpoint id are
  /// therefore independent — review v1 F1.
  private func scalarBinding<V>(
    _ keyPath: WritableKeyPath<Endpoint, V>,
    fallback: V
  ) -> Binding<V> {
    Binding(
      get: { store.endpoint(id: endpointID)?[keyPath: keyPath] ?? fallback },
      set: { newValue in
        guard var e = store.endpoint(id: endpointID) else {
          // Endpoint deleted under the editor — drop the in-flight write
          // but log so the failure is greppable in Console.app rather
          // than silently swallowed (review v2 F2).
          Log.app.error("endpoint scalar write dropped — id \(endpointID.uuidString, privacy: .public) missing from store")
          return
        }
        e[keyPath: keyPath] = newValue
        store.upsert(e)
      }
    )
  }

  private func curlSnippet(for endpoint: Endpoint) -> String {
    var lines: [String] = [
      "curl \(endpoint.baseURL) \\",
      "  -H 'Content-Type: application/json' \\",
    ]
    if let token = endpoint.authToken {
      lines.append("  -H 'Authorization: Bearer \(token)' \\")
    }
    lines.append(contentsOf: [
      "  -d '{",
      "    \"model\": \"\(endpoint.profileID)\",",
      "    \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}],",
      "    \"stream\": true",
      "  }'",
    ])
    return lines.joined(separator: "\n")
  }
}

// MARK: - request-log pane

/// Live tail of requests served by this endpoint (design §5 — "live
/// request-log tail"). Empty until the helper-side SSE proxy + log
/// stream land in Phase 5; for now it renders a labelled placeholder so
/// the split-view shape is final and the AX identity is stable.
private struct RequestLogPane: View {
  let endpoint: Endpoint

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Request log", systemImage: "list.bullet.rectangle")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
      ContentUnavailableView(
        endpoint.status == .running ? "Waiting for requests…" : "Endpoint not running",
        systemImage: "waveform",
        description: Text(
          endpoint.status == .running
            ? "Incoming /v1/chat/completions calls will appear here."
            : "Start the endpoint from the toolbar to begin serving."
        )
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    .accessibilityIdentifier("EndpointRequestLog")
  }
}
