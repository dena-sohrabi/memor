import Foundation

/// Keeps the study pal's name and your settings in iCloud key-value storage,
/// so they're the same on all your iPads and come back after a reinstall.
/// The settings themselves stay in `UserDefaults` (and `@AppStorage`); this
/// copies them to iCloud when they change here, and back when they change on
/// another iPad. Your API keys aren't settings: they stay in this iPad's
/// Keychain.
@MainActor
enum CloudSettings {
    /// Where she and her card sit isn't here, since screens differ.
    static let keys = [
        StudyPalCharacter.nameKey,
        "studyPal.nameAsked",
        PalMind.settingKey,
        PalBrainModel.settingKey,
        Pal.modeKey,
        StudyPalSpeaker.voiceKey,
        StudyPalSpeaker.isEnabledKey,
        StudyPalVoice.isEnabledKey,
        PalMemoryStore.isOnKey,
        NotebookLayout.settingKey,
    ]

    private static var isStarted = false
    /// Writing a setting from iCloud posts a change here; that change isn't
    /// sent back, or settings not yet read would go up with their old values.
    private static var isPulling = false

    /// Call once, at launch.
    static func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NotificationCenter.default
        // Changed on another iPad, or iCloud's first download on this one.
        _ = center.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated {
                pull(changed ?? keys)
                // iCloud drops what's saved before its first download on an
                // iPad, so anything it doesn't have yet goes up again.
                push()
            }
        }
        // Changed here.
        _ = center.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { _ in
            MainActor.assumeIsolated { push() }
        }
        // Every change here goes to iCloud right away, so what's there is
        // the newest; settings it doesn't have go up.
        pull(keys)
        push()
    }

    private static func pull(_ changed: [String]) {
        isPulling = true
        defer { isPulling = false }
        let cloud = NSUbiquitousKeyValueStore.default
        let defaults = UserDefaults.standard
        for key in changed where keys.contains(key) {
            guard let value = cloud.object(forKey: key), !isSame(defaults.object(forKey: key), value) else { continue }
            defaults.set(value, forKey: key)
        }
    }

    private static func push() {
        guard !isPulling else { return }
        let cloud = NSUbiquitousKeyValueStore.default
        let defaults = UserDefaults.standard
        for key in keys {
            guard let value = defaults.object(forKey: key), !isSame(cloud.object(forKey: key), value) else { continue }
            cloud.set(value, forKey: key)
        }
    }

    private static func isSame(_ stored: Any?, _ value: Any) -> Bool {
        (stored as? NSObject)?.isEqual(value) ?? false
    }
}
