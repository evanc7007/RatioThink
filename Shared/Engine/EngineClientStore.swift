import Combine

/// SwiftUI environment wrapper for the app-wide `EngineClient`.
///
/// `EngineClient` itself is a protocol existential, so it cannot be
/// injected with `environmentObject` directly. This tiny reference
/// type lets unrelated view subsystems share the same concrete
/// `HTTPEngineClient` instance that `RatioThinkApp` wires to
/// `EngineStatusStore.requireBaseURL()`.
@MainActor
public final class EngineClientStore: ObservableObject {
  public let client: EngineClient

  public init(client: EngineClient) {
    self.client = client
  }
}
