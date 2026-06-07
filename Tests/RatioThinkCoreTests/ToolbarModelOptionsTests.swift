import XCTest
@testable import RatioThinkCore

final class ToolbarModelOptionsTests: XCTestCase {
  private func appModel(_ slug: String, sizeBytes: Int64 = 100) -> InstalledModel {
    InstalledModel(filename: slug,
                   url: URL(fileURLWithPath: "/models/\(slug)"),
                   sizeBytes: sizeBytes,
                   modifiedAt: Date(timeIntervalSince1970: 0),
                   isPartial: false,
                   source: .appManaged)
  }

  private func hfModel(_ slug: String, sizeBytes: Int64 = 100) -> InstalledModel {
    InstalledModel(filename: slug,
                   url: URL(fileURLWithPath: "/hf/\(slug)"),
                   sizeBytes: sizeBytes,
                   modifiedAt: Date(timeIntervalSince1970: 0),
                   isPartial: false,
                   source: .huggingFaceCache)
  }

  func test_build_lists_app_hf_served_profile_default_and_current_without_duplicates() {
    let options = ToolbarModelOptions.build(
      discoveredModels: [
        appModel("App/Alpha.gguf"),
        hfModel("HF/Beta.safetensors"),
        hfModel("served/Resident.gguf"),
      ],
      servedModelIDs: ["served/Resident.gguf", "served/RemoteOnly.gguf"],
      profileDefaultModelID: "defaults/ProfileDefault.gguf",
      modelOverride: nil,
      residentModelID: "served/Resident.gguf")

    XCTAssertEqual(options.map(\.slug), [
      "App/Alpha.gguf",
      "HF/Beta.safetensors",
      "defaults/ProfileDefault.gguf",
      "served/RemoteOnly.gguf",
      "served/Resident.gguf",
    ])
    XCTAssertEqual(options.first { $0.slug == "served/Resident.gguf" }?.isCurrent, true)
    XCTAssertEqual(options.first { $0.slug == "defaults/ProfileDefault.gguf" }?.isProfileDefault, true)
    XCTAssertEqual(options.first { $0.slug == "HF/Beta.safetensors" }?.displayName, "Beta.safetensors")
  }

  func test_current_label_uses_actual_model_leaf_not_default_when_profile_default_is_selected() {
    let summary = ToolbarModelOptions.currentSummary(
      modelOverride: nil,
      residentModelID: nil,
      profileDefaultModelID: "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")

    XCTAssertEqual(summary?.slug, "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")
    XCTAssertEqual(summary?.displayName, "Qwen3-0.6B-Q8_0.gguf")
    XCTAssertEqual(summary?.annotation, "Profile default")
  }

  func test_override_takes_current_precedence_over_resident_and_profile_default() {
    let summary = ToolbarModelOptions.currentSummary(
      modelOverride: "override/Chosen.gguf",
      residentModelID: "resident/Loaded.gguf",
      profileDefaultModelID: "default/Profile.gguf")

    XCTAssertEqual(summary?.slug, "override/Chosen.gguf")
    XCTAssertEqual(summary?.displayName, "Chosen.gguf")
    XCTAssertNil(summary?.annotation)
  }
}
