import Foundation

/// Independent opt-ins. The old engine switch enabled both capabilities.
public struct FeatureSettings: Equatable, Sendable {
    public static let inputCleanupKey = "wds.inputCleanupEnabled.v1"
    public static let sourceSeparationKey = "wds.sourceSeparationEnabled.v1"
    public static let legacyEnabledKey = "wds.enabled"

    public var inputCleanupEnabled: Bool
    public var sourceSeparationEnabled: Bool

    public var anyEnabled: Bool { inputCleanupEnabled || sourceSeparationEnabled }

    public init(inputCleanupEnabled: Bool = false, sourceSeparationEnabled: Bool = false) {
        self.inputCleanupEnabled = inputCleanupEnabled
        self.sourceSeparationEnabled = sourceSeparationEnabled
    }

    public init(defaults: UserDefaults) {
        let legacy = defaults.bool(forKey: Self.legacyEnabledKey)
        inputCleanupEnabled = defaults.object(forKey: Self.inputCleanupKey) as? Bool ?? legacy
        sourceSeparationEnabled = defaults.object(forKey: Self.sourceSeparationKey) as? Bool ?? legacy
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(inputCleanupEnabled, forKey: Self.inputCleanupKey)
        defaults.set(sourceSeparationEnabled, forKey: Self.sourceSeparationKey)
    }
}
