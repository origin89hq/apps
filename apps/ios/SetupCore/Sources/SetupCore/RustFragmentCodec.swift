import Foundation
import Origin89SetupCore
import SetupKit

/// KM43 BLE fragmentation (P-036, P-037, P-039) from the Rust core. One per
/// connection; ``BluetoothTransport`` resets it on every open and drop.
public final class RustFragmentCodec: FragmentCodec {
  private let codec = BleCodec()

  public init() {}

  public func reset() { codec.reset() }

  public func fragments(for message: Data, valueLimit: Int) throws(TransportError) -> [Data] {
    guard let limit = UInt32(exactly: valueLimit) else { throw .dropped }
    do { return try codec.fragments(message: message, valueLimit: limit) } catch {
      throw .dropped
    }
  }

  public func receive(fragment: Data, nowMs: UInt64) throws(TransportError) -> Data? {
    do { return try codec.receive(fragment: fragment, nowMs: nowMs) } catch { throw .dropped }
  }
}

extension SetupKit.BluetoothIdentifiers {
  /// The KM43 GATT service and characteristics, from the Rust core's km43.
  public static var km43: Self {
    let ids = Origin89SetupCore.bluetoothIdentifiers()
    return Self(service: ids.service, rx: ids.rx, tx: ids.tx)
  }
}
