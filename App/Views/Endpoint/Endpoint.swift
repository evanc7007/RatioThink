import Foundation
import SwiftUI

/// API endpoint = saved chat-apc profile bound to a fixed port (design §5).
/// The list / detail / toolbar in Phase 3.7 render this model; the actual
/// TOML-backed `EndpointStore` and helper-side SSE proxy land in a later
/// task (plan §3.7 — "Helper exposes start endpoint XPC").
struct Endpoint: Identifiable, Hashable {
  let id: UUID
  var name: String
  var profileID: String
  var port: Int
  var authToken: String?
  var corsOrigins: [String]
  var status: Status

  enum Status: Hashable {
    case stopped
    case running
    case error(String)
  }

  /// `http://127.0.0.1:<port>/v1/chat/completions` — the canonical URL
  /// surfaced in the list row + curl example. Loopback-only by design;
  /// LAN exposure is a v2 setting.
  var baseURL: String { "http://127.0.0.1:\(port)/v1/chat/completions" }

  init(
    id: UUID = UUID(),
    name: String,
    profileID: String,
    port: Int,
    authToken: String? = nil,
    corsOrigins: [String] = [],
    status: Status = .stopped
  ) {
    self.id = id
    self.name = name
    self.profileID = profileID
    self.port = port
    self.authToken = authToken
    self.corsOrigins = corsOrigins
    self.status = status
  }
}

extension Endpoint.Status {
  /// Status-dot color per design §5 (● green / ○ gray / red error).
  var dotColor: Color {
    switch self {
    case .running:    return .green
    case .stopped:    return .gray
    case .error:      return .red
    }
  }

  var dotSymbol: String {
    switch self {
    case .running: return "circle.fill"
    case .stopped: return "circle"
    case .error:   return "circle.fill"
    }
  }

  var label: String {
    switch self {
    case .running:        return "Running"
    case .stopped:        return "Stopped"
    case .error(let msg): return "Error — \(msg)"
    }
  }
}

/// In-memory placeholder for the TOML-backed `EndpointStore`. Real
/// persistence to `~/Library/Application Support/RatioThink/endpoints.toml` lands
/// alongside the helper start/stop XPC in Phase 5. Until then this keeps
/// the UI demonstrable + the view-binding shape final.
@MainActor
final class EndpointStore: ObservableObject {
  @Published var endpoints: [Endpoint]

  init(endpoints: [Endpoint] = []) {
    self.endpoints = endpoints
  }

  func endpoint(id: UUID) -> Endpoint? {
    endpoints.first(where: { $0.id == id })
  }

  func upsert(_ endpoint: Endpoint) {
    if let idx = endpoints.firstIndex(where: { $0.id == endpoint.id }) {
      endpoints[idx] = endpoint
    } else {
      endpoints.append(endpoint)
    }
  }

  func remove(id: UUID) {
    endpoints.removeAll { $0.id == id }
  }

  /// Create, store, and return a new stopped endpoint on the next free
  /// port (starting at 11434, the Ollama default). Shared by the list
  /// empty-state CTA and the col-3 zero-state "Add Endpoint" CTA so port
  /// allocation lives in one place.
  @discardableResult
  func createEndpoint() -> Endpoint {
    let used = Set(endpoints.map(\.port))
    var port = 11434
    while used.contains(port) { port += 1 }
    let endpoint = Endpoint(name: "New Endpoint", profileID: "chat", port: port)
    upsert(endpoint)
    return endpoint
  }
}
