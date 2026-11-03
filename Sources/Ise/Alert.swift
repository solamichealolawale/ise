import AppKit

enum Alert: Equatable {
    case none
    /// The current block has not been started 3 minutes after it came up.
    case notStarted
    /// A started block ran past its time.
    case overrun
    /// The current block has been paused for 10 minutes or more.
    case pausedTooLong
    /// A parked block or blocked step reached its chase time.
    case chase

    var repeatAfter: TimeInterval? {
        switch self {
        case .notStarted: return 3 * 60
        case .overrun: return 5 * 60
        case .pausedTooLong: return 10 * 60
        case .none, .chase: return nil
        }
    }

    func playSound() {
        switch self {
        case .none: break
        case .notStarted: Sound.play("Funk", times: 2)
        case .overrun: Sound.play("Sosumi", times: 3)
        case .chase: Sound.play("Ping")
        case .pausedTooLong: Sound.play("Submarine")
        }
    }
}

enum Sound {
    static func play(_ name: String, times: Int = 1) {
        for repeatIndex in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(repeatIndex) * 1.2) {
                NSSound(named: NSSound.Name(name))?.play()
            }
        }
    }
}
