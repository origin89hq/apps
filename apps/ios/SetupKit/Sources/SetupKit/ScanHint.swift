/// When to offer help because the camera has not found a code.
///
/// The scanner calls `scanStarted(at:)` when the camera starts and again on
/// every rescan, which restarts the wait. The hint shows once `delay` has
/// passed without a code, and stays hidden for the rest of the scan session
/// after `dismiss()`. Time comes from the caller, so any clock drives it.
public struct ScanHint<Instant: InstantProtocol>: Sendable where Instant.Duration == Duration {
  public static var defaultDelay: Duration { .seconds(8) }

  public let delay: Duration
  public private(set) var isDismissed = false
  private var startedAt: Instant?

  public init(delay: Duration = Self.defaultDelay) {
    self.delay = delay
  }

  /// When the hint should appear, or nil when it never will: no scan is
  /// running, or the person dismissed it.
  public var deadline: Instant? {
    guard !isDismissed, let startedAt else { return nil }
    return startedAt.advanced(by: delay)
  }

  public func isVisible(at now: Instant) -> Bool {
    guard let deadline else { return false }
    return now >= deadline
  }

  /// The camera started or rearmed after a refused code: wait the full delay again.
  public mutating func scanStarted(at now: Instant) { startedAt = now }

  /// The camera stopped, after a code was accepted or the scanner closed.
  public mutating func scanStopped() { startedAt = nil }

  /// Hide the hint for this scan session, including later rescans.
  public mutating func dismiss() { isDismissed = true }
}
