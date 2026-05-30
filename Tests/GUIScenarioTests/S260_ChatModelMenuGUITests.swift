import XCTest

///  - first-launch chat model menu includes the seeded
/// default profile model. This stays GUI-level but avoids the real
/// engine path: the placeholder menu is static app UI until `/v1/models`
/// wiring replaces it.
final class S260_ChatModelMenuGUITests: XCTestCase {
  override func setUp() async throws {
    try guardSeatedGUI()
  }

  @MainActor
  func test_chat_model_menu_contains_seeded_qwen3_default() async throws {
    let pieHome = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-s260-model-menu-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: pieHome, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: pieHome) }

    let app = XCUIApplication(bundleIdentifier: "com.ratiothink.app")
    app.launchArguments.append(contentsOf: [
      "-NSQuitAlwaysKeepsWindows", "NO",
      "-ApplePersistenceIgnoreState", "YES",
    ])
    app.launchEnvironment["PIE_HOME"] = pieHome.path
    configureCompletedFirstLaunch(app, suiteName: stablePreferenceSuiteName(pieHome.path))
    app.launch()
    defer { app.terminate() }

    XCTAssert(app.wait(for: .runningForeground, timeout: 10),
              "RatioThink.app did not reach runningForeground")
    app.activate()

    let newChat = app.buttons["chats.newButton"]
    XCTAssertTrue(newChat.waitForExistence(timeout: 10),
                  "New Chat button missing; app tree: \(app.debugDescription)")
    newChat.click()

    let modelMenu = app.menuButtons["toolbar.model"]
    XCTAssertTrue(modelMenu.waitForExistence(timeout: 10),
                  "model menu missing after creating chat; app tree: \(app.debugDescription)")
    modelMenu.click()

    //  F1: seeded default aligned to the recommended curated
    // starter's file (Qwen3-0.6B-Q8_0.gguf).
    let seededModel = app.menuItems["Qwen3-0.6B-Q8_0.gguf"]
    XCTAssertTrue(seededModel.waitForExistence(timeout: 3),
                  "seeded Qwen3 default model missing from chat model menu; app tree: \(app.debugDescription)")
    app.typeKey(.escape, modifierFlags: [])
  }
}
