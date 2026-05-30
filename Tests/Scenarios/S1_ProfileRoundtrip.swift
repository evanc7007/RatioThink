import Foundation

/// S1 — User-authored Profile TOML round-trips losslessly.
///
/// v1 fields parse correctly. v2 sections (`mcp_servers`, `routine`, `remote`, `agent`)
/// are preserved verbatim through parse → dump even though v1 ignores them.
public enum S1_ProfileRoundtrip {
  public static let title = "Profile lossless round-trip"

  public static let toml = """
  id = "chat"
  name = "Chat"
  model = "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M.gguf"
  inferlet = "chat-apc"
  system_prompt = "You are helpful."

  [sampling]
  temperature = 0.7
  top_p = 0.9
  max_tokens = 2048

  [inferlet_args]
  apc_enabled = true

  [[mcp_servers]]
  command = "uvx some-server"

  [routine]
  cron = "0 9 * * *"

  [remote]
  url = "wss://remote.example.com"

  [agent]
  loop = "react"
  """

  public static func run<R: ScenarioRunner>(_ r: R) async throws {
    try await r.step("parse v1 fields") {
      let p = try await r.parseProfile(toml: toml)
      try r.require(p.id == "chat", "id mismatch: \(p.id)")
      try r.require(p.name == "Chat", "name mismatch: \(p.name)")
      try r.require(p.inferlet == "chat-apc")
      try r.require(p.sampling.temperature == 0.7)
      try r.require(p.sampling.maxTokens == 2048)
    }

    try await r.step("dump preserves all v2 sections") {
      let p = try await r.parseProfile(toml: toml)
      let dumped = try await r.dumpProfile(p)
      for marker in ["mcp_servers", "uvx some-server",
                     "0 9 * * *", "wss://remote.example.com", "react"] {
        try r.require(dumped.contains(marker), "marker '\(marker)' missing in dump")
      }
    }
  }
}
