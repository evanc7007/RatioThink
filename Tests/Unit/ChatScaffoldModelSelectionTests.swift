import XCTest
@testable import RatioThink

@MainActor
final class ChatScaffoldModelSelectionTests: XCTestCase {
  func test_nothing_resolvable_returns_nil_so_send_is_blocked() {
    // : no hidden "default" sentinel. With no test override, no
    // per-chat override, and nothing resident, resolution yields nil —
    // the caller must block the send and show the no-model confirm
    // rather than silently asking the engine to load something.
    let selected = ChatScaffoldView.requestModelID(
      modelOverride: nil,
      residentModelID: nil,
      testModelID: nil
    )
    XCTAssertNil(selected)
  }

  func test_placeholder_models_include_seeded_default_profile_model() throws {
    let seededProfile = try Profile.parse(toml: ProfileStore.defaultChatTOML)

    XCTAssertTrue(
      ChatTranscriptViewModel.placeholderModels.contains(seededProfile.model),
      "placeholderModels must include the seeded default profile model so the first-launch model picker matches chat.toml"
    )
  }

  func test_explicit_model_override_and_resident_model_take_precedence_over_profile_default() {
    XCTAssertEqual(
      ChatScaffoldView.requestModelID(
        modelOverride: "explicit-model",
        residentModelID: "resident-model",
        testModelID: nil
      ),
      "explicit-model"
    )
    XCTAssertEqual(
      ChatScaffoldView.requestModelID(
        modelOverride: nil,
        residentModelID: "resident-model",
        testModelID: nil
      ),
      "resident-model"
    )
  }

  func test_chat_gui_override_still_points_at_small_model_harness() {
    XCTAssertEqual(
      ChatScaffoldView.requestModelID(
        modelOverride: nil,
        residentModelID: nil,
        testModelID: "Qwen/Qwen3-0.6B"
      ),
      "Qwen/Qwen3-0.6B"
    )
  }

  func test_default_load_click_starts_engine_even_while_status_is_starting_placeholder() {
    XCTAssertEqual(
      ChatScaffoldView.defaultLoadAction(for: .starting),
      .startEngine,
      "the no-model sheet's explicit Load click must kick the engine even if the status poll is still on the initial .starting placeholder; otherwise the first click is swallowed until a later .stopped poll"
    )
  }

  func test_default_load_action_preserves_existing_status_mapping() {
    XCTAssertEqual(ChatScaffoldView.defaultLoadAction(for: .running(port: 1234, profileID: "chat")), .loadDirect)
    XCTAssertEqual(ChatScaffoldView.defaultLoadAction(for: .stopped), .startEngine)
    XCTAssertEqual(
      ChatScaffoldView.defaultLoadAction(for: .failed(code: .engineGone, message: "gone")),
      .startEngine
    )
    XCTAssertEqual(
      ChatScaffoldView.defaultLoadAction(for: .failed(code: .memoryRisk, message: "too large")),
      .none
    )
    XCTAssertEqual(ChatScaffoldView.defaultLoadAction(for: .stopping), .none)
  }
}
