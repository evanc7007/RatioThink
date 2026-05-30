import SwiftUI
import TOMLKit

/// Read-only per-profile editor (Phase 3.8). The *Show advanced*
/// toggle uncovers the inferlet picker + raw `inferlet_args` so users
/// can inspect what would be sent to the engine; writing is deferred
/// to a follow-up so this pane can land without touching the
/// `ProfileStore` FS-watcher path.
struct ProfileEditor: View {
  let entry: ProfileLoadResult
  /// Invoked after a successful model write so the parent re-scans and
  /// hands back a refreshed `entry`. .
  var onModelChanged: () -> Void = {}
  @EnvironmentObject private var profileStore: ProfileStore
  @State private var showAdvanced: Bool = false
  @State private var installedModels: [String] = []
  @State private var modelWriteError: String?
  /// Set when `InstalledModels.scan` throws ( F2). Without this the
  /// picker silently rendered empty on a scan failure, so a permission
  /// glitch on the models dir looked like "no models installed".
  /// Mirrors `ModelsSettingsTab`'s `scanError` surfacing.
  @State private var modelScanError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let profile = entry.profile {
          headerRow(profile: profile)
          coreSection(profile: profile)
          if !(profile.systemPrompt ?? "").isEmpty {
            systemPromptSection(profile.systemPrompt!)
          }
          samplingSection(profile: profile)
          warningsSection
          advancedToggle
          if showAdvanced {
            advancedSection(profile: profile)
          }
        } else if let error = entry.error {
          unparsableSection(error)
        }
        Spacer(minLength: 0)
      }
      .padding(20)
    }
    .accessibilityIdentifier("ProfileEditor")
    .task { await refreshInstalledModels() }
  }

  // MARK: - Sections

  private func headerRow(profile: Profile) -> some View {
    HStack(alignment: .firstTextBaseline) {
      if let icon = profile.icon, !icon.isEmpty {
        Image(systemName: icon).foregroundStyle(.secondary)
      }
      Text(profile.name).font(.title3).bold()
      Spacer()
      Text(profile.id).monospaced().foregroundStyle(.tertiary)
    }
  }

  private func coreSection(profile: Profile) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsSectionHeader(title: "Model")
      SettingsLabeledRow(label: "Default model") {
        modelPicker(profile: profile)
      }
      if let modelWriteError {
        Text(modelWriteError)
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let modelScanError {
        Text(modelScanError)
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("ProfileEditorModelScanError")
      }
      SettingsLabeledRow(label: "Inferlet") {
        Text(profile.inferlet).monospaced().textSelection(.enabled)
      }
      SettingsLabeledRow(label: "File") {
        Text(entry.url.lastPathComponent).monospaced().foregroundStyle(.secondary)
      }
    }
  }

  /// Pull-down of installed GGUF models (+ the profile's current model
  /// even if uninstalled). Selecting a model persists it as the
  /// profile's default via `ProfileStore.setModel`. This is a default
  /// for the swap-confirm PRE-FILL only — it never triggers a load.
  private func modelPicker(profile: Profile) -> some View {
    Menu {
      ForEach(ProfileModelOptions.merge(installed: installedModels,
                                        current: profile.model), id: \.self) { model in
        Button {
          persistModel(model, profileID: profile.id)
        } label: {
          // Value is the resolvable slug; label is the friendly leaf
          // ( review v2 F1).
          if model == profile.model {
            Label(ModelDisplayName.leaf(model), systemImage: "checkmark")
          } else {
            Text(ModelDisplayName.leaf(model))
          }
        }
      }
    } label: {
      HStack(spacing: 4) {
        Text(ModelDisplayName.leaf(profile.model)).monospaced()
        Image(systemName: "chevron.up.chevron.down").font(.caption)
      }
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityIdentifier("ProfileEditorModelPicker")
  }

  private func systemPromptSection(_ prompt: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsSectionHeader(title: "System prompt")
      Text(prompt)
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
  }

  private func samplingSection(profile: Profile) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsSectionHeader(title: "Sampling")
      SettingsLabeledRow(label: "Temperature") {
        Text(String(format: "%.2f", profile.sampling.temperature))
          .monospaced()
      }
      SettingsLabeledRow(label: "Top P") {
        Text(String(format: "%.2f", profile.sampling.topP))
          .monospaced()
      }
      SettingsLabeledRow(label: "Max tokens") {
        Text("\(profile.sampling.maxTokens)").monospaced()
      }
    }
  }

  @ViewBuilder
  private var warningsSection: some View {
    if !entry.warnings.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        SettingsSectionHeader(title: "Warnings")
        ForEach(entry.warnings, id: \.section) { w in
          HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle")
              .foregroundStyle(.orange)
            Text(w.description).font(.callout)
          }
        }
      }
    }
  }

  private var advancedToggle: some View {
    Toggle("Show advanced", isOn: $showAdvanced)
      .toggleStyle(.switch)
      .accessibilityIdentifier("ProfileEditorShowAdvancedToggle")
  }

  private func advancedSection(profile: Profile) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsSectionHeader(title: "Inferlet picker")
      // Phase 3.8: picker shows the current inferlet only — actual
      // wasm enumeration lives in RatioThinkHelper and is not yet exposed
      // back to the App for selection. Surfacing the field here
      // documents the eventual interaction without faking choices
      // the engine wouldn't accept.
      SettingsLabeledRow(label: "Inferlet binary") {
        Text(profile.inferlet).monospaced().textSelection(.enabled)
      }

      Text("`inferlet_args` (raw)")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
      Text(rawInferletArgs(profile.inferletArgs))
        .monospaced()
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
  }

  private func unparsableSection(_ error: ProfileError) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      SettingsSectionHeader(title: "Cannot parse")
      Text(error.description)
        .foregroundStyle(.red)
        .textSelection(.enabled)
      SettingsLabeledRow(label: "File") {
        Text(entry.url.path).monospaced().lineLimit(2).truncationMode(.middle)
      }
    }
  }

  // MARK: - side effects

  private func persistModel(_ model: String, profileID: String) {
    guard model != entry.profile?.model else { return }
    do {
      try profileStore.setModel(model, forProfileID: profileID)
      modelWriteError = nil
      onModelChanged()
    } catch {
      modelWriteError = "Could not set default model: \(error)"
    }
  }

  @MainActor
  private func refreshInstalledModels() async {
    do {
      let dir = try PieDirs.models()
      installedModels = try InstalledModels.scan(dir).map(\.filename)
      modelScanError = nil
    } catch {
      //  F2: surface the failure instead of `try?`-swallowing to an
      // empty picker. The current profile model still shows (merged in by
      // `ProfileModelOptions.merge`); this just explains why the rest is
      // missing.
      installedModels = []
      modelScanError = "Could not read installed models: \(error)"
    }
  }

  // MARK: - helpers

  /// Stable, locale-free dump of `inferlet_args`. Encoding through a
  /// `TOMLTable` keeps the string identical to what would land on
  /// disk when write-back ships.
  private func rawInferletArgs(_ args: [String: TOMLValueConvertible]) -> String {
    if args.isEmpty { return "(none)" }
    let table = TOMLTable()
    for k in args.keys.sorted() {
      if let v = args[k] { table[k] = v }
    }
    return table.convert()
  }
}
