/// Lets one scanned code through per scan.
///
/// A camera reports the same code many times a second while it stays in view.
/// The gate passes the first non-empty string and drops everything after it
/// until `rearm()`, which the scanner calls when the person scans again. It
/// does not judge whether a string is a setup code; `SetupFlow.submitCode`
/// and the Rust parser behind it do.
public struct ScanGate: Sendable {
  public private(set) var isOpen = true

  public init() {}

  /// The string to submit, or nil when it is empty or a code already passed.
  public mutating func pass(_ scanned: String?) -> String? {
    guard isOpen, let scanned, !scanned.isEmpty else { return nil }
    isOpen = false
    return scanned
  }

  /// Accept the next code, after the last one was refused.
  public mutating func rearm() { isOpen = true }
}
