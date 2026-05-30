import SwiftUI
import AppKit

/// *Settings → Advanced* — developer-leaning controls: reveal data
/// dirs in Finder, open log files. Phase 3.8 shipped the read-only
/// Reveal affordances. ( removed the preferences-reset section; the
/// only surviving preference is the first-launch completion flag.)
struct AdvancedSettingsTab: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {

        SettingsSectionHeader(title: "Data locations")
        VStack(alignment: .leading, spacing: 6) {
          revealRow(label: "Application support",
                    accessibilityID: "RevealAppSupport") {
            try PieDirs.applicationSupport()
          }
          revealRow(label: "Models",
                    accessibilityID: "RevealModels") {
            try PieDirs.models()
          }
          revealRow(label: "Profiles",
                    accessibilityID: "RevealProfiles") {
            try PieDirs.profiles()
          }
          revealRow(label: "Inferlets",
                    accessibilityID: "RevealInferlets") {
            try PieDirs.inferlets()
          }
          revealRow(label: "Logs",
                    accessibilityID: "RevealLogs") {
            try PieDirs.logs()
          }
        }

        Spacer(minLength: 0)
      }
      .padding(20)
    }
  }

  @ViewBuilder
  private func revealRow(label: String,
                          accessibilityID: String,
                          _ resolve: @escaping () throws -> URL) -> some View {
    let resolved = resolvedRow(resolve)
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(label).foregroundStyle(.secondary)
        Spacer()
        Text(resolved.displayPath)
          .monospaced()
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: 280, alignment: .trailing)
          .textSelection(.enabled)
          .help(resolved.errorMessage ?? resolved.displayPath)
        Button {
          if let url = resolved.url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
        } label: {
          Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        // Promote the typed PieDirsError into the tooltip so a click
        // on the disabled folder button explains *why* (review v2 F6).
        .help(resolved.errorMessage ?? "Reveal in Finder")
        .accessibilityIdentifier(accessibilityID)
        .disabled(resolved.url == nil)
      }
      if let msg = resolved.errorMessage {
        Text(msg)
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  private struct ResolvedRow {
    let url: URL?
    let displayPath: String
    let errorMessage: String?
  }

  private func resolvedRow(_ resolve: () throws -> URL) -> ResolvedRow {
    do {
      let u = try resolve()
      return ResolvedRow(url: u, displayPath: u.path, errorMessage: nil)
    } catch let err as PieDirsError {
      return ResolvedRow(url: nil,
                         displayPath: "—",
                         errorMessage: err.description)
    } catch {
      return ResolvedRow(url: nil,
                         displayPath: "—",
                         errorMessage: String(describing: error))
    }
  }
}
