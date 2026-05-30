import Foundation
import RatioThinkCore

// Minimal probe binary that prints `HelperConfig` + `PieDirs` resolution
// using the actual production code paths. Tests spawn this with a
// constructed env so prod-side env-fallback regressions are caught —
// previous RatioThinkCoreTests inlined hand-written resolvers, which made the
// env subprocess probes vacuous (review v4 F9).
//
// Modes:
//   config      print `xpc=<name>` + `testMode=<bool>`
//   dirs        print `appSupport=<path>` (or stderr + exit 1)
//   all         both
//   double-read perform two `HelperConfig.xpcServiceName` reads under
//               two distinct `$overrides.withValue` scopes (review v6
//               F1). Arguments:
//                 --first <xpc>:<testMode>
//                 --second <xpc>:<testMode>
//               where `<xpc>` is the override service name (or `nil`)
//               and `<testMode>` is `true|false|nil`. Each successful
//               read prints `pair<N>-ok=<xpc>`; a trap exits with the
//               OS-default fatalError code (non-zero). Lets tests
//               assert the in-process per-read validation actually
//               re-runs across successive override scopes.

let args = CommandLine.arguments
let mode = args.count >= 2 ? args[1] : "all"

func printConfig() {
  print("xpc=\(HelperConfig.xpcServiceName)")
  print("testMode=\(HelperConfig.isTestMode)")
}

func printDirs() {
  do {
    let root = try PieDirs.applicationSupport()
    print("appSupport=\(root.standardizedFileURL.path)")
  } catch {
    FileHandle.standardError.write(Data("pie-resolve-probe: \(error)\n".utf8))
    exit(1)
  }
}

func parseOverridePair(_ spec: String) -> HelperConfig.Overrides {
  // spec is "<xpc>:<testMode>". Empty / `nil` token means nil.
  let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
  guard parts.count == 2 else {
    FileHandle.standardError.write(Data("pie-resolve-probe: bad override spec '\(spec)' (expected <xpc>:<testMode>)\n".utf8))
    exit(2)
  }
  let xpcRaw  = String(parts[0])
  let testRaw = String(parts[1])
  let xpc: String?  = (xpcRaw.isEmpty || xpcRaw == "nil") ? nil : xpcRaw
  let test: Bool?
  switch testRaw {
  case "true":   test = true
  case "false":  test = false
  case "", "nil": test = nil
  default:
    FileHandle.standardError.write(Data("pie-resolve-probe: bad testMode '\(testRaw)' (expected true|false|nil)\n".utf8))
    exit(2)
  }
  return HelperConfig.Overrides(xpcServiceName: xpc, testMode: test)
}

func doubleRead() {
  // Expect: double-read --first <pair1> --second <pair2>
  var first: HelperConfig.Overrides?
  var second: HelperConfig.Overrides?
  var i = 2
  while i < args.count {
    let flag = args[i]
    let value: String? = (i + 1 < args.count) ? args[i + 1] : nil
    switch flag {
    case "--first":
      guard let value else { FileHandle.standardError.write(Data("--first needs value\n".utf8)); exit(2) }
      first = parseOverridePair(value); i += 2
    case "--second":
      guard let value else { FileHandle.standardError.write(Data("--second needs value\n".utf8)); exit(2) }
      second = parseOverridePair(value); i += 2
    default:
      FileHandle.standardError.write(Data("pie-resolve-probe: unknown flag '\(flag)'\n".utf8)); exit(2)
    }
  }
  guard let first, let second else {
    FileHandle.standardError.write(Data("double-read requires --first and --second\n".utf8))
    exit(2)
  }

  // First read — establishes "the once-guard would have armed here".
  // Flush after each print so a later fatalError doesn't lose
  // already-produced output (line-buffering on a pipe).
  HelperConfig.$overrides.withValue(first) {
    let name = HelperConfig.xpcServiceName  // traps if pair1 is asymmetric
    print("pair1-ok=\(name)")
    fflush(stdout)
  }
  // Second read — under v5+ this re-validates and traps on asymmetry.
  // Under v4's once-guard this would silently succeed.
  HelperConfig.$overrides.withValue(second) {
    let name = HelperConfig.xpcServiceName
    print("pair2-ok=\(name)")
    fflush(stdout)
  }
}

switch mode {
case "config":
  printConfig()
case "dirs":
  printDirs()
case "all":
  printConfig()
  printDirs()
case "double-read":
  doubleRead()
default:
  FileHandle.standardError.write(Data("pie-resolve-probe: unknown mode '\(mode)' (expected config|dirs|all|double-read)\n".utf8))
  exit(2)
}
