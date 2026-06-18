import SwiftUI
import AppKit

/// *Settings → Profiles* — list of `<PIE_HOME>/profiles/*.toml` with a
/// read-only per-profile editor. Phase 3.8 ships display + the
/// "Show advanced" toggle that reveals the inferlet picker and raw
/// `inferlet_args`. Write-back lives in a follow-up so this
/// pane can land without touching `ProfileStore`'s FS-watcher path.
struct ProfilesSettingsTab: View {
  @State private var entries: [ProfileLoadResult] = []
  @State private var directoryError: String?
  @State private var selectionURL: URL?

  var body: some View {
    HSplitView {
      list
        .frame(minWidth: 220, maxWidth: 280)
      detail
        .frame(minWidth: 320, maxWidth: .infinity)
    }
    .task { await refresh() }
  }

  // MARK: - List

  private var list: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        SettingsSectionHeader(title: "Profiles")
        Spacer()
        Button {
          revealProfilesDirInFinder()
        } label: {
          Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help("Reveal profiles directory in Finder")
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)

      if let directoryError {
        Text(directoryError)
          .foregroundStyle(.red)
          .padding(12)
      }

      if entries.isEmpty && directoryError == nil {
        VStack {
          Spacer()
          Text("No profiles yet.")
            .foregroundStyle(.secondary)
          Spacer()
        }
      } else {
        List(selection: $selectionURL) {
          ForEach(entries, id: \.url) { entry in
            ProfileListRow(entry: entry)
              .tag(Optional(entry.url))
          }
        }
        .listStyle(.sidebar)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  // MARK: - Detail

  private var detail: some View {
    Group {
      if let url = selectionURL,
         let entry = entries.first(where: { $0.url == url }) {
        ProfileEditor(entry: entry, onModelChanged: { Task { await refresh() } })
      } else {
        VStack(spacing: 6) {
          Spacer()
          Image(systemName: "person.crop.rectangle")
            .font(.system(size: 36))
            .foregroundStyle(.tertiary)
          Text("Select a profile")
            .foregroundStyle(.secondary)
          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  // MARK: - Side effects

  @MainActor
  private func refresh() async {
    do {
      let dir = try PieDirs.profiles()
      // Use the shared `ProfileStore.scan` rather than re-implementing
      // the TOML enumeration here (review v2 F9). The duplicate scan
      // previously matched `*.toml` case-insensitively while the
      // canonical store matches the literal lowercase extension; a
      // `*.TOML` file would have rendered in one path and not the
      // other.
      let (loaded, scanErr) = ProfileStore.scan(directory: dir)
      entries = loaded
      directoryError = scanErr.map(String.init(describing:))
      if selectionURL == nil { selectionURL = entries.first?.url }
    } catch {
      directoryError = String(describing: error)
      entries = []
    }
  }

  /// Routes the resolve failure through `directoryError` so it
  /// surfaces in the existing red-text block instead of silently
  /// no-op'ing (review v2 F7).
  private func revealProfilesDirInFinder() {
    do {
      let dir = try PieDirs.profiles()
      NSWorkspace.shared.activateFileViewerSelecting([dir])
    } catch {
      directoryError = "Reveal profiles directory failed: \(error)"
    }
  }
}

// MARK: - List row

private struct ProfileListRow: View {
  let entry: ProfileLoadResult

  var body: some View {
    HStack(spacing: 6) {
      if !entry.isValid {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .help(entry.error?.description ?? "")
      } else if !entry.warnings.isEmpty {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .help(entry.warnings.map(\.description).joined(separator: "\n"))
      }
      VStack(alignment: .leading) {
        Text(displayName)
          .lineLimit(1)
        if let caption {
          Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
  }

  private var displayName: String {
    entry.profile?.name ?? entry.url.deletingPathExtension().lastPathComponent
  }

  private var caption: String? {
    guard let p = entry.profile else { return nil }
    let trimmed = p.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? p.id : trimmed
  }
}
