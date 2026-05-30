import SwiftUI

/// : shown when the user sends a chat with no model resolvable (no
/// per-chat override and nothing resident). The send is blocked — RatioThink
/// never loads a model the user did not explicitly choose. Offers to
/// load the active profile's default model now, pick another from the
/// toolbar, or cancel. Loading spends RAM only as a direct consequence
/// of the user tapping Load here.
struct NoModelLoadedPrompt: View {
  /// The active profile's default model, pre-filled into the Load
  /// action. Nil when the active profile is missing/unparsable — Load
  /// is then disabled and the copy points at the toolbar / Settings.
  let profileDefaultModel: String?
  let onLoad: (String) -> Void
  let onChooseAnother: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        Image(systemName: "cpu")
          .foregroundStyle(.secondary)
        Text("No model loaded")
          .font(.headline)
      }

      if let model = profileDefaultModel {
        Text("Load this profile's default model to send your message?")
          .fixedSize(horizontal: false, vertical: true)
        // Stored model is the resolvable slug; show the friendly leaf
        // ( review v2 F1).
        Text(ModelDisplayName.leaf(model))
          .monospaced()
          .lineLimit(1)
          .truncationMode(.middle)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
      } else {
        Text("This profile has no default model. Choose one from the Model menu in the toolbar.")
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button("Cancel", role: .cancel) { onCancel() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Choose another") { onChooseAnother() }
          .accessibilityIdentifier("noModel.chooseAnother")
        if let model = profileDefaultModel {
          Button("Load") { onLoad(model) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("noModel.load")
        }
      }
    }
    .padding(20)
    .frame(width: 360)
    .accessibilityIdentifier("noModel.prompt")
  }
}
