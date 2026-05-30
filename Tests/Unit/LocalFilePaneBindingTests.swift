import XCTest
import SwiftUI
@testable import RatioThink

/// Review v6 F40 / review v7 F45 contract: `LocalFilePane.error`
/// must be a `@Binding`-backed slot owned by the parent
/// (`AddModelSheet`), not a pane-local `@State`. SwiftUI tears down
/// pane-local `@State` when the parent's `Group { switch
/// selectedSource }` swaps the pane out — a user who picks a non-
/// gguf file (caption shown) then clicks Curated / Search Hugging
/// Face to investigate alternatives and returns previously lost the
/// caption.
///
/// Review v7 F45 flagged that the prior persistence test only
/// asserted Swift closure-capture, which holds for either `@State`
/// or `@Binding`. The rewritten test below writes through the
/// parent-owned binding *after* the first pane is constructed and
/// then discards it, mirroring SwiftUI tearing down the subtree on
/// a Picker swap; if the field regresses to `@State` the
/// reconstructed pane reads its default (`nil`) and the assertion
/// fires. The Mirror-based test pins the storage type so the
/// regression is caught even before render.
final class LocalFilePaneBindingTests: XCTestCase {

  func test_error_binding_storage_survives_pane_reconstruction() {
    var stored: String?
    let binding = Binding<String?>(
      get: { stored },
      set: { stored = $0 }
    )

    // First pane lifetime — simulates SwiftUI's initial subtree
    // construction. The pane is intentionally constructed and then
    // immediately discarded; the caption is written *through the
    // parent-owned binding* mid-life, which is the only mechanism
    // a `@State` field would NOT pick up on the rebuild.
    do {
      _ = LocalFilePane(modelsDirectory: nil,
                        error: binding,
                        onBatch: { _, _ in })
      binding.wrappedValue = "ModelImporter: '/tmp/x.bin' must have a .gguf extension"
    }
    // Pane discarded — mirrors SwiftUI tearing down the subtree
    // when the user clicks a sibling Source tab.

    // Re-mount against the SAME binding. Under `@Binding`, the
    // rebuilt pane reads the stored value through the binding's
    // get-closure; under `@State`, the rebuilt pane's storage is
    // re-initialised to the property's default (`nil`).
    let rebuilt = LocalFilePane(modelsDirectory: nil,
                                error: binding,
                                onBatch: { _, _ in })

    XCTAssertEqual(
      rebuilt.error,
      "ModelImporter: '/tmp/x.bin' must have a .gguf extension",
      "rebuilt LocalFilePane MUST read the parent-owned caption through the Binding (review v7 F45) — a `@State` regression would surface `nil` here")
    XCTAssertEqual(stored,
                   "ModelImporter: '/tmp/x.bin' must have a .gguf extension",
                   "parent-owned storage must still carry the caption after the pane lifetimes")
  }

  func test_setting_error_through_binding_mutates_parent_storage() {
    var stored: String?
    let binding = Binding<String?>(get: { stored }, set: { stored = $0 })
    let pane = LocalFilePane(modelsDirectory: nil,
                             error: binding,
                             onBatch: { _, _ in })
    pane.error = "after-set"
    XCTAssertEqual(stored, "after-set",
                   "writes through `pane.error` (`Binding<String?>.wrappedValue`) must hit the parent's storage; if F40 regresses to `@State`, this assertion fires")
  }

  /// Pin the storage type. Mirror reflects the underscored
  /// property-wrapper backing (`_error`); if a future refactor
  /// reverts to `@State var error: String?`, the runtime type
  /// changes from `Binding<…>` to `State<…>` and this test fires
  /// at construction time — before any render-driven assertion
  /// could (review v7 F45).
  func test_error_field_storage_is_binding_not_state() {
    let binding = Binding<String?>(get: { nil }, set: { _ in })
    let pane = LocalFilePane(modelsDirectory: nil,
                             error: binding,
                             onBatch: { _, _ in })
    let mirror = Mirror(reflecting: pane)
    guard let underscored = mirror.children.first(where: { $0.label == "_error" }) else {
      XCTFail("LocalFilePane must store its caption slot under property-wrapper `_error`")
      return
    }
    let typeName = String(describing: type(of: underscored.value))
    XCTAssertTrue(
      typeName.hasPrefix("Binding<"),
      "the `_error` storage MUST be Binding<…>; got `\(typeName)`. A regression to @State would report `State<…>` and is what review v7 F45 asks us to fence at runtime.")
  }
}
