import SwiftUI

/// Hairline vertical divider used between logical groups in the flat
/// content-toolbar (design §5). 1pt wide, secondary tint at low alpha
/// — matches Notes.app's inline formatting bar separators rather than
/// SwiftUI's default `Divider()` which inherits a heavier system color.
struct FlatDivider: View {
  /// Total vertical extent of the hairline. Toolbar icons are 22pt; we
  /// inset the divider to 16pt so it visually breathes inside the row.
  var height: CGFloat = 16

  var body: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.35))
      .frame(width: 1, height: height)
      .accessibilityHidden(true)
  }
}
