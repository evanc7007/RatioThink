import Foundation

/// Hand-curated catalog of GGUF models surfaced in *Settings → Models →
/// Add Model → Curated* so first-run users have a one-click path
/// instead of needing to know HF repo coordinates. Each entry maps
/// 1:1 to a `ModelDownloader.start(repo:file:)` call.
///
/// Curation policy (Phase 3.8): two small chat-capable GGUF builds
/// per family the engine has been smoke-tested with. Entries are
/// data-only — adding/removing models is a pure source change and
/// requires no migration since the catalog is not persisted.
public struct CuratedModel: Equatable, Identifiable, Sendable {
  /// Stable identifier for SwiftUI list diffing. Mirrors the `model`
  /// field a Profile would carry once installed, so the same string
  /// flows through `ProfileSwapCoordinator` later.
  public let id: String
  public let displayName: String
  public let publisher: String
  public let parameterCountBillions: Double
  public let quantization: String
  public let approximateSizeBytes: Int64
  public let huggingFaceRepo: String
  public let huggingFaceFile: String
  public let summary: String

  public init(id: String,
              displayName: String,
              publisher: String,
              parameterCountBillions: Double,
              quantization: String,
              approximateSizeBytes: Int64,
              huggingFaceRepo: String,
              huggingFaceFile: String,
              summary: String) {
    self.id = id
    self.displayName = displayName
    self.publisher = publisher
    self.parameterCountBillions = parameterCountBillions
    self.quantization = quantization
    self.approximateSizeBytes = approximateSizeBytes
    self.huggingFaceRepo = huggingFaceRepo
    self.huggingFaceFile = huggingFaceFile
    self.summary = summary
  }
}

public enum CuratedModelCatalog {
  /// Sorted ascending by approximate size so the table reads from
  /// "smallest, fastest first run" to "biggest, best quality" without
  /// callers needing to re-sort.
  public static let all: [CuratedModel] = baseEntries.sorted {
    $0.approximateSizeBytes < $1.approximateSizeBytes
  }

  /// `O(n)` lookup is fine — the catalog is ≤ 16 entries by design.
  public static func model(withID id: String) -> CuratedModel? {
    all.first { $0.id == id }
  }

  /// Id of the recommended starter model surfaced with a "Recommended"
  /// badge in *Settings → Models → Add Model → Curated*. :
  /// small, modern, engine-detectable. Its `<huggingFaceRepo>/<huggingFaceFile>`
  /// is exactly the slug `chat.toml` is seeded with
  /// (`ProfileStore.defaultChatModelID` =
  /// `Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf`), so downloading the
  /// recommended starter stages the very file the seeded profile's
  /// default resolves to. `CuratedModelCatalogTests` pins that
  /// resolution invariant.
  public static let recommendedModelID = "qwen3-0.6b-q8_0"

  private static let baseEntries: [CuratedModel] = [
    //  starter tier — small, modern, engine-detectable GGUF
    // builds verified against their Hugging Face repos. Sizes are the
    // exact published blob sizes so the table + ETA estimate are honest.
    CuratedModel(
      id: "qwen2.5-0.5b-instruct-q4_k_m",
      displayName: "Qwen2.5 0.5B Instruct",
      publisher: "Alibaba",
      parameterCountBillions: 0.5,
      quantization: "Q4_K_M",
      approximateSizeBytes: 491_400_032,
      huggingFaceRepo: "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
      huggingFaceFile: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
      summary: "Smallest curated model. Instant first-run smoke test."
    ),
    CuratedModel(
      id: "qwen3-0.6b-q8_0",
      displayName: "Qwen3 0.6B",
      publisher: "Alibaba",
      parameterCountBillions: 0.6,
      quantization: "Q8_0",
      approximateSizeBytes: 639_446_688,
      huggingFaceRepo: "Qwen/Qwen3-0.6B-GGUF",
      huggingFaceFile: "Qwen3-0.6B-Q8_0.gguf",
      summary: "Recommended starter — same model RatioThink seeds as the default chat profile."
    ),
    CuratedModel(
      id: "llama-3.2-1b-instruct-q4_k_m",
      displayName: "Llama 3.2 1B Instruct",
      publisher: "Meta",
      parameterCountBillions: 1.0,
      quantization: "Q4_K_M",
      approximateSizeBytes: 807_694_464,
      huggingFaceRepo: "bartowski/Llama-3.2-1B-Instruct-GGUF",
      huggingFaceFile: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
      summary: "Tiny Llama. Quick everyday chat at minimal VRAM."
    ),
    CuratedModel(
      id: "qwen2.5-1.5b-instruct-q4_k_m",
      displayName: "Qwen2.5 1.5B Instruct",
      publisher: "Alibaba",
      parameterCountBillions: 1.5,
      quantization: "Q4_K_M",
      approximateSizeBytes: 1_117_000_000,
      huggingFaceRepo: "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
      huggingFaceFile: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
      summary: "Compact Qwen for fast everyday chat."
    ),
    CuratedModel(
      id: "llama-3.2-3b-instruct-q4_k_m",
      displayName: "Llama 3.2 3B Instruct",
      publisher: "Meta",
      parameterCountBillions: 3.0,
      quantization: "Q4_K_M",
      approximateSizeBytes: 2_020_000_000,
      huggingFaceRepo: "bartowski/Llama-3.2-3B-Instruct-GGUF",
      huggingFaceFile: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
      summary: "Solid daily-driver chat at low VRAM."
    ),
    CuratedModel(
      id: "phi-3.5-mini-instruct-q4_k_m",
      displayName: "Phi-3.5 Mini Instruct",
      publisher: "Microsoft",
      parameterCountBillions: 3.8,
      quantization: "Q4_K_M",
      approximateSizeBytes: 2_390_000_000,
      huggingFaceRepo: "bartowski/Phi-3.5-mini-instruct-GGUF",
      huggingFaceFile: "Phi-3.5-mini-instruct-Q4_K_M.gguf",
      summary: "Reasoning-leaning Phi family build."
    ),
    CuratedModel(
      id: "qwen2.5-7b-instruct-q4_k_m",
      displayName: "Qwen2.5 7B Instruct",
      publisher: "Alibaba",
      parameterCountBillions: 7.0,
      quantization: "Q4_K_M",
      approximateSizeBytes: 4_680_000_000,
      huggingFaceRepo: "Qwen/Qwen2.5-7B-Instruct-GGUF",
      huggingFaceFile: "qwen2.5-7b-instruct-q4_k_m.gguf",
      summary: "Bigger Qwen with broader general capability."
    ),
    CuratedModel(
      id: "llama-3.1-8b-instruct-q4_k_m",
      displayName: "Llama 3.1 8B Instruct",
      publisher: "Meta",
      parameterCountBillions: 8.0,
      quantization: "Q4_K_M",
      approximateSizeBytes: 4_920_000_000,
      huggingFaceRepo: "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF",
      huggingFaceFile: "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf",
      summary: "Llama 3.1 mid-size; long-form quality bump over 3B."
    ),
  ]
}
