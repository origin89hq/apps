import os

/// Setup logs, readable from Console or Xcode on a bench session. They name
/// steps, message types, outcomes and error codes; never a payload, a key,
/// the passphrase, an SSID, the setup code, a token or an email address.
public enum SetupLog {
  public static let subsystem = "com.origin89.apps"
  static let bluetooth = Logger(subsystem: subsystem, category: "bluetooth")
  static let webSocket = Logger(subsystem: subsystem, category: "websocket")
  static let flow = Logger(subsystem: subsystem, category: "flow")
  static let account = Logger(subsystem: subsystem, category: "account")
}
