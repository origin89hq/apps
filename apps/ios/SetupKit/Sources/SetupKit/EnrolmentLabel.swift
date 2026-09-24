import Foundation

/// The label a phone enrols under: its model, a space and a random suffix.
///
/// The model is generic ("iPhone"), so the suffix alone keeps phones apart,
/// and a re-pair with a byte-identical label reclaims that row (P-078). km43
/// limits a Pair `label` to `MAX_LABEL`, 32 UTF-8 bytes; the longest model,
/// "iPod touch", with a space and 8 hex digits is 19 bytes.
public enum EnrolmentLabel {
  /// A fixed-width suffix: 8 uppercase hex digits, zero-padded.
  public static func suffix(_ value: UInt32) -> String { String(format: "%08X", value) }
  public static func label(model: String, suffix: String) -> String { "\(model) \(suffix)" }
}
