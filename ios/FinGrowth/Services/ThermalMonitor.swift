import Foundation
import Observation

// Thermal management for on-device inference (P5-02).
//
// Observes ProcessInfo.thermalState and translates it into an inference policy:
//
//   * .serious  → reduce the token budget (512 → 128) and warn the user.
//   * .critical → "above serious": queue new work instead of running it, and
//                 resume only once thermals return to .nominal.
//
// State changes arrive via ProcessInfo's notification (event-driven), so there
// is no polling loop to pace.
//
// The split matters — at .serious we still run (just smaller); only above
// .serious do we stop scheduling work, which is what keeps a long session from
// driving the device into a thermal shutdown.
@MainActor
@Observable
final class ThermalMonitor {
    private(set) var state: ProcessInfo.ThermalState

    // Token budgets by thermal state. Nominal/fair run at the caller's base.
    static let seriousTokenCap = 128
    static let criticalTokenCap = 64

    @ObservationIgnored private var clearanceWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(
        observingNotifications: Bool = true,
        initialState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) {
        self.state = initialState
        guard observingNotifications else { return }
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            let newState = ProcessInfo.processInfo.thermalState
            Task { @MainActor in self?.applyState(newState) }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // Token reduction + user warning kick in at .serious and above.
    var isThrottling: Bool { state == .serious || state == .critical }

    // Queue new work only *above* .serious (i.e. .critical), per the design.
    var shouldQueueWork: Bool { state == .critical }

    /// Token budget for the current thermal state, never exceeding `base`.
    func recommendedMaxTokens(base: Int) -> Int {
        switch state {
        case .nominal, .fair: return base
        case .serious: return min(base, Self.seriousTokenCap)
        case .critical: return min(base, Self.criticalTokenCap)
        @unknown default: return min(base, Self.seriousTokenCap)
        }
    }

    var warningMessage: String? {
        switch state {
        case .serious:
            return "Your device is warm — on-device AI is throttled to protect it."
        case .critical:
            return "Your device is too hot — on-device AI is paused until it cools down."
        default:
            return nil
        }
    }

    /// Suspends while work should be queued (thermals above .serious) and
    /// resumes once they return to .nominal. Returns immediately otherwise.
    /// Honors cancellation so a torn-down request never leaks its continuation.
    func awaitClearance() async {
        guard shouldQueueWork else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if shouldQueueWork {
                    clearanceWaiters[id] = continuation
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeWaiter(id) }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        clearanceWaiters.removeValue(forKey: id)?.resume()
    }

    /// Update the observed state and release any queued work once fully cool.
    /// Internal so the notification handler and tests share one path.
    func applyState(_ newState: ProcessInfo.ThermalState) {
        state = newState
        guard newState == .nominal, !clearanceWaiters.isEmpty else { return }
        let waiters = clearanceWaiters
        clearanceWaiters.removeAll()
        for (_, continuation) in waiters { continuation.resume() }
    }
}
