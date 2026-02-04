import Foundation
import Combine

/// Mock user settings for testing
@MainActor
final class MockUserSettings: ObservableObject {

    @Published var refreshIntervalRaw: Int = 300  // 5 minutes default
    @Published var resetSoundRaw: String = "none"

    var refreshInterval: RefreshInterval {
        RefreshInterval(rawValue: refreshIntervalRaw) ?? .fiveMinutes
    }

    var resetSound: ResetSound {
        ResetSound(rawValue: resetSoundRaw) ?? .none
    }

    // For testing: track if sound was played
    private(set) var soundPlayedCount = 0

    func resetSoundPlayCount() {
        soundPlayedCount = 0
    }
}
