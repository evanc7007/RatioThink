import SwiftUI

/// *Settings → General* — app-wide info and toggles that don't fit
/// any other tab. Phase 3.8 ships read-only diagnostics (version,
/// PIE_HOME path) plus a launch-at-login affordance stub. The toggle
/// state lives in `AppPreferences` so the value survives relaunch;
/// wiring it to `SMAppService` is deferred to the helper-side work
/// that owns LoginItems registration.
struct GeneralSettingsTab: View {
  @State private var resolvedPieHome: String = "—"

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        SettingsSectionHeader(title: "About")
        VStack(alignment: .leading, spacing: 6) {
          SettingsLabeledRow(label: "Version") {
            Text(Self.versionString)
              .monospaced()
              .textSelection(.enabled)
          }
          SettingsLabeledRow(label: "Bundle") {
            Text(Bundle.main.bundleIdentifier ?? "—")
              .monospaced()
              .textSelection(.enabled)
          }
          SettingsLabeledRow(label: "PIE_HOME") {
            Text(resolvedPieHome)
              .monospaced()
              .textSelection(.enabled)
              .lineLimit(2)
              .truncationMode(.middle)
          }
        }

        Divider()

        SettingsSectionHeader(title: "Startup")
        Text("Open RatioThink at login is configured by the menu-bar helper (RatioThinkHelper) via SMAppService and is not yet exposed here. Until that switch ships, you can register the helper from System Settings → General → Login Items.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Spacer(minLength: 0)
      }
      .padding(20)
    }
    .task {
      await MainActor.run { resolvedPieHome = Self.resolvePieHome() }
    }
  }

  private static var versionString: String {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }

  /// Mirror of `PieDirs.resolveRoot()` for display only. We hit the
  /// throwing primitive here so a permissions failure does not block
  /// the General tab from rendering — the error message is shown in
  /// place of the path.
  private static func resolvePieHome() -> String {
    do {
      return try PieDirs.applicationSupport().path
    } catch {
      return "error: \(error)"
    }
  }
}
