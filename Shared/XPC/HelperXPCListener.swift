import Foundation
import os
import Security

/// Owns the helper's `NSXPCListener` plus the `NSXPCListenerDelegate`
/// that gates incoming connections on caller identity (Team ID match).
///
/// Two start modes:
///
///  1. `startMachService(exportedObject:)` — production path. Binds the
///     listener to `HelperConfig.xpcServiceName`. The mach service name
///     is the only piece of state that varies between prod (canonical
///     `com.ratiothink.helper`) and parallel tests (`com.ratiothink.helper.test.<uuid>`).
///     Requires a launchd-registered job (SMAppService.loginItem at
///     install time) — peer processes find the service via
///     `bootstrap_look_up`. Ad-hoc-signed dev binaries cannot
///     self-publish a mach service this way, hence the dev path below.
///
///  2. `startAnonymous(exportedObject:)` — debug + integration-test
///     path. **Not for production callers** — gated to test mode or
///     `PIE_ALLOW_UNSIGNED_CALLERS=1` under DEBUG (review v1 F3).
///     Returns an owner whose `endpoint` can be passed to a
///     same-process `NSXPCConnection(listenerEndpoint:)`. The plan doc
///     calls this the "UDS dev fallback"; the actual mechanism is
///     `NSXPCListener.anonymous()`. `NSXPCConnection` only speaks
///     mach service or `NSXPCListenerEndpoint`, and
///     `NSXPCListenerEndpoint` is encodable only over `NSXPCCoder` —
///     so the endpoint cannot be archived to disk or shipped across
///     process boundaries via any public API.
///
/// Identity check (`listener(_:shouldAcceptNewConnection:)`):
///
///  · Pulls the caller's `audit_token_t` off the connection via KVC
///    (`auditToken`). `NSXPCConnection` exposes the field this way; it
///    is the documented cookbook pattern for caller-identity gates.
///  · `SecCodeCopyGuestWithAttributes` with
///    `kSecGuestAttributeAudit` resolves the caller to a `SecCode`,
///    then `SecCodeCopySigningInformation` yields the Team ID.
///  · Our own Team ID comes from `SecStaticCodeCreateWithPath(Bundle.main)`.
///  · Bypassed when `HelperConfig.isTestMode` is true OR — under
///    DEBUG — when the explicit `PIE_ALLOW_UNSIGNED_CALLERS=1` env
///    is set (review v1 F1 — previously every DEBUG build bypassed
///    unconditionally, which was too permissive for hand-distributed
///    dev binaries).
///
/// Startup self-tests (review v1 F5 + F11): `verifyStartupInvariants()`
/// — called eagerly from `assertStartupContract` — opens a
/// same-process `NSXPCConnection`, asserts the KVC `auditToken`
/// extraction still produces a `MemoryLayout<audit_token_t>.size`-shaped
/// blob, and reads `selfTeamID()` so a Security framework outage at
/// boot fails loudly instead of silently rejecting every later
/// production connection.
///
/// Lifetime: `HelperXPCListener` retains the underlying `NSXPCListener`
/// and the exported object. Drop the returned value to tear the
/// listener down (callers normally hold it for app lifetime).
public final class HelperXPCListener: NSObject, NSXPCListenerDelegate {
  private let listener: NSXPCListener
  /// Swappable on a live listener (review v3 F1). The delegate reads
  /// the current value through `exportedObjectLock` each time a peer
  /// connects, so `setExportedObject(_:)` from another thread can
  /// transition the helper into degraded mode WITHOUT rebinding the
  /// mach service name. The prior v2 design invalidated and rebuilt
  /// the listener under a new mach name registration, which raced
  /// launchd's publish/unpublish step — `NSXPCListener.invalidate()`
  /// returning does not mean launchd has finished unpublishing.
  /// Atomic swap removes the rebind entirely.
  ///
  /// Visibility contract (review v4 F3): `setExportedObject` is
  /// guaranteed to affect connections whose
  /// `shouldAcceptNewConnection` body STARTS after `setExportedObject`
  /// returns. The delegate holds `exportedObjectLock` from its
  /// `withLock` open through the in-block `newConnection.resume()`,
  /// so a swap that arrives mid-accept blocks until the accept body
  /// finishes — that connection retains the pre-swap object. Peer
  /// connections already past `resume()` retain their per-connection
  /// `exportedObject` assignment (NSXPC is sticky), as do peers
  /// holding live proxies. The product invariant ("degraded-mode
  /// callers mid-RPC see their original wire shape; new peers see
  /// `.degraded`") still holds under this tighter window.
  private let exportedObjectLock: OSAllocatedUnfairLock<PieHelperXPC>
  private let exportedInterface: NSXPCInterface
  /// Captured at listener construction time. The delegate runs on
  /// libdispatch's private queue — outside any `@TaskLocal` override
  /// scope — so reading `HelperConfig.isTestMode` from within the
  /// delegate would observe the *process-env* value and miss the
  /// per-test `IsolatedTestCase` override (review v1 follow-up).
  /// Freezing the bypass decision here makes it deterministic for
  /// the listener's lifetime.
  private let capturedBypassReason: String?
  private static let log = Logger(subsystem: "com.ratiothink.app.helper", category: "xpc.listener")
  private static let bypassLogged = OSAllocatedUnfairLock<Bool>(initialState: false)

  /// The listener's `endpoint`. Only meaningful for the anonymous
  /// mode; the mach-service mode returns an endpoint that peers
  /// resolve via `bootstrap_look_up` instead.
  public var endpoint: NSXPCListenerEndpoint { listener.endpoint }

  /// Tear down the underlying `NSXPCListener`. Production consumers:
  ///  · `HelperAppDelegate.applicationWillTerminate` (review v4 F2)
  /// graceful-termination paths only: `NSApp.terminate` and the
  ///    SIGTERM AppKit's runloop catches. Does NOT cover SIGKILL,
  ///    SIGABRT, SIGSEGV/BUS, `os_unfair_lock` aborts, or Swift
  ///    runtime traps — under those signals the listener never
  ///    `invalidate`s and the mach registration is unpublished by
  ///    launchd's port-rights cleanup at process death (review v5
  ///    F3).
  ///  · `HelperAppDelegate.transitionToDegradedOrTerminate` —
  ///    explicit pre-`exit(_:)` cleanup on the fail-loud path
  ///    (review v5 F1), because `exit(_:)` skips
  ///    `applicationWillTerminate`.
  ///
  /// Either consumer gives launchd the unpublication signal so peers
  /// racing the teardown see `NSXPCConnectionInvalid` from
  /// `bootstrap_look_up` instead of a half-published stale
  /// registration.
  ///
  /// Degraded-mode transitions do NOT call this — review v3 F1
  /// replaced the listener rebind with an in-place
  /// `setExportedObject` swap to avoid racing launchd's
  /// publish/unpublish step. `invalidate` is reserved for shutdown.
  ///
  /// Idempotent: a second call is a no-op (`NSXPCListener.invalidate`
  /// itself is idempotent).
  public func invalidate() {
    listener.invalidate()
    Self.log.info("xpc listener: invalidated")
  }

  private init(listener: NSXPCListener,
               exportedObject: PieHelperXPC,
               forceIdentityCheck: Bool = false) {
    self.listener = listener
    self.exportedObjectLock = OSAllocatedUnfairLock(initialState: exportedObject)
    self.exportedInterface = PieHelperXPCInterface.make()
    self.capturedBypassReason = forceIdentityCheck ? nil : CallerIdentity.bypassReason()
    super.init()
    listener.delegate = self
  }

  /// Swap the exported object atomically on a live listener (review
  /// v3 F1). The swap is guaranteed visible to peer connections
  /// whose `shouldAcceptNewConnection` body STARTS after this method
  /// returns (review v4 F3). Connections already mid-accept retain
  /// the pre-swap object — the delegate holds
  /// `exportedObjectLock` from its read through `newConnection.resume()`,
  /// so a swap arriving mid-accept blocks until that accept finishes.
  /// Connections past `resume()` likewise retain their per-connection
  /// `exportedObject` assignment (NSXPC is sticky).
  ///
  /// Replaces the prior v2 `transitionToDegraded` path that
  /// invalidated and rebuilt the listener — that path raced
  /// launchd's publish/unpublish step and could leave peer connects
  /// intermittently landing on `mach-service-not-found`.
  public func setExportedObject(_ object: PieHelperXPC) {
    exportedObjectLock.withLock { $0 = object }
    Self.log.info("xpc listener: exportedObject swapped to \(String(describing: type(of: object)), privacy: .public)")
  }

  /// Bind to `HelperConfig.xpcServiceName`. Reads the resolved value
  /// (which fires `validateContract` per v5 F1), traps on contract
  /// mismatch, and gates the system-singleton side effect through the
  /// canonical assertion — review v1 F2 puts the gate adjacent to the
  /// bind so a lint scan that covers `Shared/XPC/` will find it.
  public static func startMachService(
    exportedObject: PieHelperXPC = HelperExportedAPI()
  ) -> HelperXPCListener {
    HelperConfig.assertStartupContract()
    let serviceName = HelperConfig.xpcServiceName
    // Gate sits at the actual bind so any lint scan covering Shared/XPC
    // sees an `assertSystemSideEffectAllowed(...)` in the same
    // proximity window as `NSXPCListener(machServiceName:)`.
    HelperConfig.assertSystemSideEffectAllowed("NSXPCListener")
    let listener = NSXPCListener(machServiceName: serviceName)
    let owner = HelperXPCListener(listener: listener, exportedObject: exportedObject)
    log.info("xpc listener: starting on mach service \(serviceName, privacy: .public)")
    listener.resume()
    return owner
  }

  /// Create an anonymous listener and resume it. Caller reads
  /// `endpoint` and hands it to a same-process
  /// `NSXPCConnection(listenerEndpoint:)`. Refuses outside test mode
  /// + the DEBUG-only `PIE_ALLOW_UNSIGNED_CALLERS=1` escape hatch
  /// (review v1 F3) — a release build that wandered into this code
  /// path would otherwise expose every selector to any local process.
  public static func startAnonymous(
    exportedObject: PieHelperXPC = HelperExportedAPI()
  ) -> HelperXPCListener {
    HelperConfig.assertStartupContract()
    guard isAnonymousModeAllowed() else {
      preconditionFailure("HelperXPCListener.startAnonymous() called outside PIE_TEST_MODE / DEBUG+PIE_ALLOW_UNSIGNED_CALLERS — refuse to publish an unsigned-caller listener in production")
    }
    let listener = NSXPCListener.anonymous()
    let owner = HelperXPCListener(listener: listener, exportedObject: exportedObject)
    log.info("xpc listener: starting anonymous")
    listener.resume()
    return owner
  }

  static func isAnonymousModeAllowed() -> Bool {
    if HelperConfig.isTestMode { return true }
    #if DEBUG
    return ProcessInfo.processInfo.environment["PIE_ALLOW_UNSIGNED_CALLERS"] == "1"
    #else
    return false
    #endif
  }

  /// Test-only: build a listener that ignores the captured bypass and
  /// always runs the production identity check. Lets unit tests
  /// exercise the rejection path against a real same-process
  /// `NSXPCConnection` peer (review v1 F14 — the prior coverage
  /// touched only the bypass branch).
  static func _startAnonymousForcingIdentityCheck(
    exportedObject: PieHelperXPC = HelperExportedAPI()
  ) -> HelperXPCListener {
    HelperConfig.assertStartupContract()
    guard isAnonymousModeAllowed() else {
      preconditionFailure("HelperXPCListener._startAnonymousForcingIdentityCheck called outside test mode")
    }
    let listener = NSXPCListener.anonymous()
    let owner = HelperXPCListener(listener: listener,
                                  exportedObject: exportedObject,
                                  forceIdentityCheck: true)
    listener.resume()
    return owner
  }

  // MARK: - NSXPCListenerDelegate

  public func listener(_ listener: NSXPCListener,
                       shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
    let decision = CallerIdentity.validate(connection: newConnection,
                                           capturedBypassReason: capturedBypassReason)
    switch decision {
    case .accept(let reason):
      Self.logBypassOnce(reason: reason, pid: newConnection.processIdentifier)
    case .acceptVerified:
      break
    case .reject(let error):
      Self.log.error("xpc listener: rejecting connection pid=\(newConnection.processIdentifier, privacy: .public) reason=\(String(describing: error), privacy: .public)")
      return false
    }
    // Hold the lock from read through resume() so a concurrent
    // setExportedObject cannot land between our read and the
    // resume, leaving the new connection wired to a pre-swap object
    // while the caller saw "swap took effect" (review v4 F3). The
    // delegate is called once per accept on a private libdispatch
    // queue; resume() is non-blocking so the window is microseconds.
    exportedObjectLock.withLock { exportedObject in
      newConnection.exportedInterface = exportedInterface
      newConnection.exportedObject = exportedObject
      newConnection.invalidationHandler = {
        Self.log.info("xpc connection invalidated")
      }
      newConnection.interruptionHandler = {
        Self.log.info("xpc connection interrupted")
      }
      newConnection.resume()
    }
    Self.log.info("xpc listener: accepted connection pid=\(newConnection.processIdentifier, privacy: .public)")
    return true
  }

  /// Emit a `.fault` once per process the first time a bypass fires
  /// (review v1 F1). Helps field triage distinguish "DEBUG dev
  /// helper" from "release build silently accepting unsigned
  /// callers."
  private static func logBypassOnce(reason: String, pid: pid_t) {
    let shouldLog = bypassLogged.withLock { state -> Bool in
      if state { return false }
      state = true
      return true
    }
    if shouldLog {
      log.fault("xpc identity: FIRST BYPASS (\(reason, privacy: .public)) pid=\(pid, privacy: .public) — every subsequent connection from any local peer will be accepted until process restart")
    } else {
      log.info("xpc identity: bypass (\(reason, privacy: .public)) pid=\(pid, privacy: .public)")
    }
  }

  // MARK: - startup self-test

  /// Open a same-process anonymous `NSXPCConnection` and confirm the
  /// KVC `auditToken` extraction still produces a token of the
  /// expected size. Failing loudly at boot beats silently rejecting
  /// every production connection because Apple changed the boxing
  /// shape (review v1 F5). Read of `selfTeamID()` here also defeats
  /// the F11 "permanently cached nil" risk by failing the helper
  /// boot if our own signing info isn't readable.
  ///
  /// Test-mode helpers skip the self-test: they intentionally have no
  /// Team ID and the listener is never bound to a launchd-registered
  /// mach service, so the connection path the self-test would build
  /// has no peer.
  public static func verifyStartupInvariants() {
    if HelperConfig.isTestMode {
      log.info("startup self-test: skipped under PIE_TEST_MODE=1")
      return
    }
    let bypass = CallerIdentity.bypassReason()
    // F11: refuse to boot if our own signing info is unreadable.
    // selfTeamID() caches on success; a transient failure here
    // surfaces *now* instead of poisoning every later connection.
    //
    // Review v2 F1: an ad-hoc-signed DEBUG dev build legitimately has
    // no Team Identifier — `.teamIDAbsent` is the expected reading
    // there. Trapping on it would brick every local DEBUG boot. So
    // when a bypass mode is active (test or DEBUG+env), downgrade
    // `.teamIDAbsent` to a log line; keep `.securityFrameworkFailure`
    // and `.selfIdentityUnreadable` as hard fails because those
    // indicate a Security-framework outage that would silently
    // reject every connection later anyway.
    switch CallerIdentity.selfTeamIDResult() {
    case .success(let team):
      log.info("startup self-test: selfTeamID=\(team, privacy: .public)")
    case .failure(.teamIDAbsent) where bypass != nil:
      log.info("startup self-test: selfTeamID absent (bypass=\(bypass!, privacy: .public)) — ad-hoc-signed build, proceeding")
    case .failure(let err):
      log.fault("startup self-test: cannot read own Team ID — \(String(describing: err), privacy: .public)")
      preconditionFailure("HelperXPCListener.verifyStartupInvariants: cannot read own Team ID: \(err)")
    }
    // F5: probe the KVC auditToken extraction against a same-process
    // connection. Use an anonymous listener so we don't depend on a
    // launchd-registered mach service for the probe.
    let probeListener = NSXPCListener.anonymous()
    let acceptedSize = OSAllocatedUnfairLock<Int?>(initialState: nil)
    let delegate = AuditTokenProbeDelegate(captured: acceptedSize)
    probeListener.delegate = delegate
    probeListener.resume()
    defer { probeListener.suspend() }

    let probeConnection = NSXPCConnection(listenerEndpoint: probeListener.endpoint)
    probeConnection.remoteObjectInterface = NSXPCInterface(with: AuditTokenProbeProtocol.self)
    probeConnection.resume()
    defer { probeConnection.invalidate() }

    let sem = DispatchSemaphore(value: 0)
    let proxy = probeConnection.remoteObjectProxyWithErrorHandler { err in
      log.fault("startup self-test: probe proxy error \(String(describing: err), privacy: .public)")
      sem.signal()
    } as? AuditTokenProbeProtocol
    proxy?.ping { sem.signal() }
    let waited = sem.wait(timeout: .now() + 5)
    guard waited == .success else {
      preconditionFailure("HelperXPCListener.verifyStartupInvariants: same-process probe ping timed out")
    }
    let observed = acceptedSize.withLock { $0 }
    let expected = MemoryLayout<audit_token_t>.size
    guard let observed else {
      preconditionFailure("HelperXPCListener.verifyStartupInvariants: probe delegate never observed an audit token")
    }
    guard observed == expected else {
      preconditionFailure("HelperXPCListener.verifyStartupInvariants: KVC auditToken regressed — expected \(expected) bytes, got \(observed)")
    }
    log.info("startup self-test: KVC auditToken extraction returned \(observed) bytes (expected \(expected))")
  }
}

/// Caller-identity gate. Pulled into a separate type so unit tests can
/// drive `bypassReason(for:)` without standing up a full listener.
enum CallerIdentity {
  enum Decision {
    /// Identity check was bypassed (test mode or explicit DEBUG
    /// escape hatch). Carries the human-readable reason so the
    /// listener can emit a one-time `.fault` log.
    case accept(reason: String)
    /// Identity check ran and the caller's Team ID matched ours.
    case acceptVerified
    /// Reject the connection.
    case reject(IdentityError)
  }

  /// Detailed identity failure mode (review v1 F9). Replaces the
  /// prior nil-collapse that lost the distinction between "missing
  /// audit token", "KVC type regression", and "Team ID absent."
  enum IdentityError: Error, CustomStringConvertible, Equatable {
    case auditTokenMissing
    case auditTokenWrongType(observedClass: String)
    case auditTokenWrongSize(observed: Int, expected: Int)
    case securityFrameworkFailure(api: String, osStatus: OSStatus)
    case teamIDAbsent
    /// Both sides resolved a Team Identifier but they don't match.
    /// Distinct from `.teamIDAbsent` (review v2 F3 — the prior code
    /// collapsed mismatches into "absent", losing the load-bearing
    /// triage signal of "a different signer connected").
    case teamIDMismatch(ours: String, theirs: String)
    case selfIdentityUnreadable

    var description: String {
      switch self {
      case .auditTokenMissing:
        return "auditToken KVC returned nil — caller did not present an audit token"
      case let .auditTokenWrongType(cls):
        return "auditToken KVC returned unexpected class \(cls); macOS may have changed the boxing shape"
      case let .auditTokenWrongSize(observed, expected):
        return "auditToken size \(observed) != expected \(expected) (sizeof audit_token_t)"
      case let .securityFrameworkFailure(api, status):
        return "\(api) failed with OSStatus \(status)"
      case .teamIDAbsent:
        return "caller passed SecCode resolution but has no Team Identifier in its signing info"
      case let .teamIDMismatch(ours, theirs):
        return "Team Identifier mismatch ours=\(ours) theirs=\(theirs)"
      case .selfIdentityUnreadable:
        return "could not read this process's own Team ID — Security framework outage at boot"
      }
    }
  }

  /// Run the gate. Returns a `Decision` rather than a bare `Bool` so
  /// the listener can log + count distinct failure modes.
  ///
  /// `capturedBypassReason` is the listener's frozen view of
  /// `bypassReason()` captured at listener-construction time. The
  /// delegate runs on libdispatch — outside any `@TaskLocal`
  /// override — so re-reading `bypassReason()` here would miss
  /// `IsolatedTestCase`'s per-test `HelperConfig.$overrides` and
  /// reject every test connection. Production callers pass `nil`
  /// (no captured bypass) and the live `bypassReason()` is consulted.
  static func validate(connection: NSXPCConnection,
                       capturedBypassReason: String? = nil) -> Decision {
    if let reason = capturedBypassReason ?? bypassReason() {
      return .accept(reason: reason)
    }
    let theirResult = teamID(for: connection)
    let ourResult = selfTeamIDResult()
    switch (theirResult, ourResult) {
    case let (.success(theirs), .success(ours)):
      return theirs == ours
        ? .acceptVerified
        : .reject(.teamIDMismatch(ours: ours, theirs: theirs))
    case let (.failure(err), _):
      return .reject(err)
    case (_, .failure):
      return .reject(.selfIdentityUnreadable)
    }
  }

  /// Returns a human-readable bypass reason when identity check should
  /// be skipped. Tightened in review v1 F1: DEBUG alone no longer
  /// bypasses — the explicit `PIE_ALLOW_UNSIGNED_CALLERS=1` env is
  /// required so a DEBUG binary handed to a tester (or accidentally
  /// notarized) doesn't expose every selector to any local process.
  static func bypassReason() -> String? {
    if HelperConfig.isTestMode { return "PIE_TEST_MODE=1" }
    #if DEBUG
    if ProcessInfo.processInfo.environment["PIE_ALLOW_UNSIGNED_CALLERS"] == "1" {
      return "DEBUG + PIE_ALLOW_UNSIGNED_CALLERS=1"
    }
    #endif
    return nil
  }

  /// Pull caller's Team ID from the `audit_token_t` carried by the XPC
  /// connection. Returns a typed `Result` so the listener can route
  /// each failure mode distinctly (review v1 F9).
  static func teamID(for connection: NSXPCConnection) -> Result<String, IdentityError> {
    switch auditTokenData(from: connection) {
    case .failure(let err):
      return .failure(err)
    case .success(let tokenData):
      let attrs: [String: Any] = [kSecGuestAttributeAudit as String: tokenData]
      var codeRef: SecCode?
      let status = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &codeRef)
      guard status == errSecSuccess, let code = codeRef else {
        return .failure(.securityFrameworkFailure(api: "SecCodeCopyGuestWithAttributes", osStatus: status))
      }
      return teamIDResult(forCode: code)
    }
  }

  /// `Result`-flavored counterpart so the startup self-test (F5/F11)
  /// can fail loudly with the underlying error. The cached-success
  /// path (F11) is still in place — we just never persist a `.failure`.
  static func selfTeamIDResult() -> Result<String, IdentityError> {
    if let cached = SelfIdentityCache.cachedTeamID {
      return .success(cached)
    }
    return SelfIdentityCache.readAndCache()
  }

  /// Convenience wrapper used by paths that only care about
  /// presence/absence and not the failure mode.
  static func selfTeamID() -> String? {
    switch selfTeamIDResult() {
    case .success(let team): return team
    case .failure: return nil
    }
  }

  // MARK: - internals

  /// Extract `audit_token_t` bytes from an NSXPCConnection. Validates
  /// the boxing class and the byte size so a future macOS change that
  /// swaps the box or shrinks the struct surfaces as a typed error
  /// rather than a silently-partial token (review v1 F10).
  ///
  /// `objCType` is intentionally NOT compared against a hard-coded
  /// `@encode(audit_token_t)` string: the encoded form has varied
  /// across macOS versions (`{audit_token_t=…}` vs `{?=…}`), so a
  /// strict compare would fail-closed on a benign rename. Class +
  /// size catches the load-bearing regressions (different box class
  /// like NSData→NSConcreteValue→NSNumber, or wrong byte count) which
  /// are what would actually produce a garbage token.
  static func auditTokenData(from connection: NSXPCConnection) -> Result<Data, IdentityError> {
    let expected = MemoryLayout<audit_token_t>.size
    guard let raw = connection.value(forKey: "auditToken") else {
      return .failure(.auditTokenMissing)
    }
    if let value = raw as? NSValue {
      var token = audit_token_t(val: (0,0,0,0,0,0,0,0))
      value.getValue(&token, size: expected)
      let bytes = withUnsafeBytes(of: &token) { Data($0) }
      guard bytes.count == expected else {
        return .failure(.auditTokenWrongSize(observed: bytes.count, expected: expected))
      }
      return .success(bytes)
    }
    if let data = raw as? Data {
      guard data.count == expected else {
        return .failure(.auditTokenWrongSize(observed: data.count, expected: expected))
      }
      return .success(data)
    }
    return .failure(.auditTokenWrongType(observedClass: "\(type(of: raw))"))
  }

  private static func teamIDResult(forCode code: SecCode) -> Result<String, IdentityError> {
    var staticCode: SecStaticCode?
    let conv = SecCodeCopyStaticCode(code, [], &staticCode)
    guard conv == errSecSuccess, let sc = staticCode else {
      return .failure(.securityFrameworkFailure(api: "SecCodeCopyStaticCode", osStatus: conv))
    }
    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    let copy = SecCodeCopySigningInformation(sc, flags, &info)
    guard copy == errSecSuccess, let dict = info as? [String: Any] else {
      return .failure(.securityFrameworkFailure(api: "SecCodeCopySigningInformation", osStatus: copy))
    }
    guard let team = dict[kSecCodeInfoTeamIdentifier as String] as? String else {
      return .failure(.teamIDAbsent)
    }
    return .success(team)
  }

  enum SelfIdentityCache {
    static let lock = OSAllocatedUnfairLock<String?>(initialState: nil)
    static var cachedTeamID: String? { lock.withLock { $0 } }

    static func readAndCache() -> Result<String, IdentityError> {
      var staticCode: SecStaticCode?
      let bundleURL = Bundle.main.bundleURL as CFURL
      let create = SecStaticCodeCreateWithPath(bundleURL, [], &staticCode)
      guard create == errSecSuccess, let sc = staticCode else {
        return .failure(.securityFrameworkFailure(api: "SecStaticCodeCreateWithPath", osStatus: create))
      }
      var info: CFDictionary?
      let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
      let copy = SecCodeCopySigningInformation(sc, flags, &info)
      guard copy == errSecSuccess, let dict = info as? [String: Any] else {
        return .failure(.securityFrameworkFailure(api: "SecCodeCopySigningInformation", osStatus: copy))
      }
      guard let team = dict[kSecCodeInfoTeamIdentifier as String] as? String else {
        return .failure(.teamIDAbsent)
      }
      lock.withLock { $0 = team }
      return .success(team)
    }

    /// Test-only seam: drop the cached Team ID so a unit test can
    /// re-exercise the read path (or simulate a fresh boot).
    public static func _resetForTesting() {
      lock.withLock { $0 = nil }
    }
  }
}

// MARK: - startup self-test machinery

@objc private protocol AuditTokenProbeProtocol {
  func ping(reply: @escaping () -> Void)
}

private final class AuditTokenProbe: NSObject, AuditTokenProbeProtocol {
  func ping(reply: @escaping () -> Void) { reply() }
}

/// Same-process delegate that captures the observed auditToken size
/// for the startup self-test (F5). Accepts unconditionally — the
/// probe never crosses process boundaries.
private final class AuditTokenProbeDelegate: NSObject, NSXPCListenerDelegate {
  let captured: OSAllocatedUnfairLock<Int?>
  init(captured: OSAllocatedUnfairLock<Int?>) {
    self.captured = captured
    super.init()
  }
  func listener(_ listener: NSXPCListener,
                shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
    // Capture the size we'd observe under production code paths.
    switch CallerIdentity.auditTokenData(from: newConnection) {
    case .success(let data):
      captured.withLock { $0 = data.count }
    case .failure(let err):
      Logger(subsystem: "com.ratiothink.app.helper", category: "xpc.listener").fault(
        "startup self-test: probe could not extract auditToken: \(String(describing: err), privacy: .public)"
      )
    }
    newConnection.exportedInterface = NSXPCInterface(with: AuditTokenProbeProtocol.self)
    newConnection.exportedObject = AuditTokenProbe()
    newConnection.resume()
    return true
  }
}
