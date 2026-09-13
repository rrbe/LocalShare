import AppKit

/// A session deadline uses wall time so time spent asleep still counts.
@MainActor
final class ShareAutoStop {
    static let defaultMinutes = 60
    static let presets = [10, 60, 360, 1440]
    static let customRange = 1...(99 * 60 + 59)

    private(set) var deadline: Date?
    var onExpire: (() -> Void)?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkExpiration() }
        }
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func schedule(at date: Date?) {
        cancel()
        guard let date else { return }
        deadline = date
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkExpiration() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        deadline = nil
    }

    func checkExpiration(now: Date = Date()) {
        guard let deadline, now >= deadline else { return }
        cancel()
        onExpire?()
    }
}
