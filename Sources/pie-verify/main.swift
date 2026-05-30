import Foundation
import RatioThinkCore
import TOMLKit

// Lightweight assertion harness — substitute for XCTest when only CLT is installed.
// Run with: swift run pie-verify
//
// Exits 0 on all-pass, 1 on first failure (and prints diagnostics).

var failed = 0
var ran = 0

func check(_ name: String, _ body: () throws -> Void) {
  ran += 1
  do {
    try body()
    print("PASS  \(name)")
  } catch {
    failed += 1
    print("FAIL  \(name) — \(error)")
  }
}

func expect(_ cond: Bool, _ msg: @autoclosure () -> String = "", file: String = #file, line: Int = #line) throws {
  if !cond {
    throw NSError(
      domain: "pie-verify", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "expectation failed at \(file):\(line) — \(msg())"]
    )
  }
}

func expectThrows<E: Error & Equatable>(_ expected: E, _ body: () throws -> Any) throws {
  do {
    _ = try body()
    throw NSError(domain: "pie-verify", code: 2,
                  userInfo: [NSLocalizedDescriptionKey: "expected throw of \(expected), got success"])
  } catch let actual as E where actual == expected {
    return
  } catch let other {
    throw NSError(domain: "pie-verify", code: 3,
                  userInfo: [NSLocalizedDescriptionKey: "expected \(expected), got \(other)"])
  }
}

// MARK: - Test cases

check("PieDirs paths under Application Support") {
  let root = try PieDirs.applicationSupport()
  try expect(root.path.contains("Application Support/RatioThink"),
             "got \(root.path)")
  try expect(try PieDirs.profiles().path.hasSuffix("/profiles"))
  try expect(try PieDirs.models().path.hasSuffix("/models"))
  try expect(try PieDirs.logs().path.hasSuffix("/logs"))
  try expect(try PieDirs.inferlets().path.hasSuffix("/inferlets"))
}

check("Profile.parse v1 minimal profile") {
  let toml = """
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
  """
  let p = try Profile.parse(toml: toml)
  try expect(p.id == "chat", "id = \(p.id)")
  try expect(p.name == "Chat", "name = \(p.name)")
  try expect(p.model == "bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M.gguf")
  try expect(p.inferlet == "chat-apc")
  try expect(p.systemPrompt == "You are helpful.")
  try expect(p.sampling.temperature == 0.7)
  try expect(p.sampling.topP == 0.9)
  try expect(p.sampling.maxTokens == 2048)
  try expect(p.inferletArgs["apc_enabled"]?.bool == true,
             "apc_enabled lookup failed")
}

check("Profile.parse uses defaults when sampling omitted") {
  let toml = """
  id = "x"
  name = "X"
  model = "m"
  inferlet = "chat-apc"
  """
  let p = try Profile.parse(toml: toml)
  try expect(p.sampling.temperature == 0.7)
  try expect(p.sampling.topP == 0.9)
  try expect(p.sampling.maxTokens == 2048)
}

check("Profile preserves unknown v2 sections losslessly on round-trip") {
  let toml = """
  id = "x"
  name = "X"
  model = "m"
  inferlet = "chat-apc"

  [[mcp_servers]]
  command = "uvx some-server"

  [routine]
  cron = "0 9 * * *"
  trigger = "schedule"

  [remote]
  url = "wss://remote.example.com"
  auth = "keychain:profile-x"

  [agent]
  loop = "react"
  """
  let p = try Profile.parse(toml: toml)
  let dumped = try p.dump()
  try expect(dumped.contains("mcp_servers"),
             "mcp_servers missing in dump:\n\(dumped)")
  try expect(dumped.contains("uvx some-server"),
             "command missing in dump:\n\(dumped)")
  try expect(dumped.contains("0 9 * * *"),
             "cron missing in dump:\n\(dumped)")
  try expect(dumped.contains("wss://remote.example.com"),
             "remote.url missing:\n\(dumped)")
  try expect(dumped.contains("react"),
             "agent.loop missing:\n\(dumped)")
}

check("Profile.parse throws .missingField when id omitted") {
  try expectThrows(ProfileError.missingField("id")) {
    try Profile.parse(toml: """
    name = "no id"
    model = "m"
    inferlet = "chat-apc"
    """)
  }
}

check("Profile.parse throws .missingField when model omitted") {
  try expectThrows(ProfileError.missingField("model")) {
    try Profile.parse(toml: """
    id = "x"
    name = "X"
    inferlet = "chat-apc"
    """)
  }
}

check("Profile.parse throws .parseFailure on invalid TOML") {
  do {
    _ = try Profile.parse(toml: "this = is = not = toml")
    print("FAIL  expected parse error")
    failed += 1
  } catch ProfileError.parseFailure {
    // expected
  } catch {
    print("FAIL  expected .parseFailure, got \(error)")
    failed += 1
  }
}

// MARK: - Report

print("")
print("Ran \(ran) checks; \(failed) failure(s).")
exit(failed == 0 ? 0 : 1)
