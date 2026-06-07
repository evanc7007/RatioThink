import Foundation

/// Pure option-list builder for the chat toolbar's model menu.
///
/// The toolbar is a selection surface, not merely an engine-introspection
/// surface: it must offer every model the user can reasonably choose
/// (app-managed files, Hugging Face cache rows, the currently served engine
/// id, and the active profile default), while keeping the selected/resident
/// identity visible as the concrete model leaf rather than a generic
/// "Default" sentinel.
public enum ToolbarModelOptions {
  public struct Option: Equatable, Sendable, Identifiable {
    public let slug: String
    public let displayName: String
    public let source: CachedModelSource?
    public let isCurrent: Bool
    public let isProfileDefault: Bool

    public var id: String { slug }

    public init(slug: String,
                displayName: String,
                source: CachedModelSource?,
                isCurrent: Bool,
                isProfileDefault: Bool) {
      self.slug = slug
      self.displayName = displayName
      self.source = source
      self.isCurrent = isCurrent
      self.isProfileDefault = isProfileDefault
    }
  }

  public struct CurrentSummary: Equatable, Sendable {
    public let slug: String
    public let displayName: String
    /// Secondary status, e.g. "Profile default". The display name remains
    /// the concrete model leaf so collapsed controls never say only Default.
    public let annotation: String?

    public init(slug: String, displayName: String, annotation: String?) {
      self.slug = slug
      self.displayName = displayName
      self.annotation = annotation
    }
  }

  public static func currentSummary(modelOverride: String?,
                                    residentModelID: String?,
                                    profileDefaultModelID: String?) -> CurrentSummary? {
    if let slug = normalized(modelOverride) {
      return CurrentSummary(slug: slug,
                            displayName: ModelDisplayName.leaf(slug),
                            annotation: nil)
    }
    if let slug = normalized(residentModelID) {
      return CurrentSummary(slug: slug,
                            displayName: ModelDisplayName.leaf(slug),
                            annotation: nil)
    }
    if let slug = normalized(profileDefaultModelID) {
      return CurrentSummary(slug: slug,
                            displayName: ModelDisplayName.leaf(slug),
                            annotation: "Profile default")
    }
    return nil
  }

  public static func build(discoveredModels: [InstalledModel],
                           servedModelIDs: [String],
                           profileDefaultModelID: String?,
                           modelOverride: String?,
                           residentModelID: String?) -> [Option] {
    let currentSlug = currentSummary(modelOverride: modelOverride,
                                     residentModelID: residentModelID,
                                     profileDefaultModelID: profileDefaultModelID)?.slug
    let profileDefault = normalized(profileDefaultModelID)

    var bySlug: [String: InstalledModel?] = [:]
    func add(_ slug: String?, model: InstalledModel? = nil) {
      guard let slug = normalized(slug), bySlug[slug] == nil else { return }
      bySlug[slug] = model
    }

    for model in discoveredModels {
      add(model.filename, model: model)
    }
    for id in servedModelIDs { add(id) }
    add(profileDefault)
    add(modelOverride)
    add(residentModelID)

    return bySlug.keys.sorted().map { slug in
      let model = bySlug[slug] ?? nil
      return Option(slug: slug,
                    displayName: ModelDisplayName.leaf(slug),
                    source: model?.source,
                    isCurrent: slug == currentSlug,
                    isProfileDefault: slug == profileDefault)
    }
  }

  private static func normalized(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}
