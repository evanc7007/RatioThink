import XCTest
import SwiftData
@testable import RatioThink

/// Headless coverage for the zero-state affordance wiring: the
/// shared chat-creation path the col-3 "Start Chat" CTA and the chat-list
/// New Chat button both call, plus the endpoint port allocator behind
/// "Add Endpoint" / "Create Endpoint". GUI navigation is covered in
/// S285_ZeroStateGUITests; these pin the deterministic logic.
@MainActor
final class ZeroStateActionsTests: XCTestCase {
  func test_chatCreation_persists_chat_and_returns_id() throws {
    let container = try RatioThinkModelContainer.makeInMemory()
    let context = ModelContext(container)
    let status = PersistenceStatus()

    let id = ChatCreation.create(
      in: context,
      persistenceStatus: status,
      contextLabel: "test"
    )
    let newID = try XCTUnwrap(id, "create must return the new chat id")

    let fetched = try context.fetch(FetchDescriptor<Chat>())
    XCTAssertEqual(fetched.count, 1, "create must persist exactly one chat")
    XCTAssertEqual(fetched.first?.id, newID)
    XCTAssertNil(status.lastError, "a successful create must not report a persistence error")
  }

  func test_createEndpoint_allocates_first_free_port_and_stores() {
    let store = EndpointStore()

    let first = store.createEndpoint()
    XCTAssertEqual(first.port, 11434, "first endpoint must take the Ollama-default port")
    XCTAssertEqual(store.endpoints.count, 1)

    let second = store.createEndpoint()
    XCTAssertEqual(second.port, 11435, "second endpoint must skip the taken port")
    XCTAssertEqual(store.endpoints.count, 2)
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(store.endpoint(id: second.id)?.port, 11435,
                   "the created endpoint must be retrievable from the store")
    XCTAssertEqual(second.status, .stopped, "a new endpoint starts stopped")
  }
}
