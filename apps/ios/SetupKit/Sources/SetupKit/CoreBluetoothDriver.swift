@preconcurrency import CoreBluetooth
import Foundation

/// CoreBluetooth invokes every delegate on the explicitly selected main queue.
@MainActor
final class CoreBluetoothDriver: NSObject, BluetoothDriver,
  @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate
{
  var event: ((BluetoothEvent) -> Void)?
  private var central: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var identifiers: BluetoothIdentifiers?
  private var excluded: Set<UUID> = []
  private var rx: CBCharacteristic?
  private var tx: CBCharacteristic?
  var maximumWriteLength: Int { peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 0 }
  var canSend: Bool { peripheral?.canSendWriteWithoutResponse ?? false }
  var peer: UUID? { peripheral?.identifier }

  func start(identifiers: BluetoothIdentifiers, excluding: Set<UUID>) {
    disconnect()
    self.identifiers = identifiers
    excluded = excluding
    central = CBCentralManager(delegate: self, queue: .main)
  }
  func subscribe() {
    guard let peripheral, let tx else {
      event?(.unavailable)
      return
    }
    peripheral.setNotifyValue(true, for: tx)
  }
  func write(_ value: Data) {
    guard let peripheral, let rx else {
      SetupLog.bluetooth.error("write with no connected peripheral")
      event?(.disconnected)
      return
    }
    peripheral.writeValue(value, for: rx, type: .withoutResponse)
  }
  func disconnect() {
    central?.stopScan()
    if let peripheral {
      // The delegate goes first, so no disconnect callback reports this one.
      SetupLog.bluetooth.info(
        "the app closes the link to \(peripheral.identifier, privacy: .public)")
      peripheral.delegate = nil
      central?.cancelPeripheralConnection(peripheral)
    }
    central?.delegate = nil
    central = nil
    peripheral = nil
    rx = nil
    tx = nil
  }
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central === self.central, let identifiers else { return }
    SetupLog.bluetooth.debug("central state \(central.state.rawValue, privacy: .public)")
    switch central.state {
    case .poweredOn:
      if peripheral == nil {
        SetupLog.bluetooth.info(
          "scanning, \(self.excluded.count, privacy: .public) peripherals excluded")
        central.scanForPeripherals(withServices: [CBUUID(string: identifiers.service)])
      }
    case .unknown, .resetting: break
    case .poweredOff, .unauthorized, .unsupported:
      SetupLog.bluetooth.error(
        "Bluetooth unavailable: state \(central.state.rawValue, privacy: .public)")
      event?(.unavailable)
    @unknown default:
      SetupLog.bluetooth.error(
        "Bluetooth unavailable: state \(central.state.rawValue, privacy: .public)")
      event?(.unavailable)
    }
  }
  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi: NSNumber
  ) {
    guard central === self.central, self.peripheral == nil, let identifiers,
      let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
      services.contains(CBUUID(string: identifiers.service)),
      !excluded.contains(peripheral.identifier)
    else { return }
    SetupLog.bluetooth.info(
      "connecting to \(peripheral.identifier, privacy: .public), RSSI \(rssi.intValue, privacy: .public)"
    )
    self.peripheral = peripheral
    peripheral.delegate = self
    central.stopScan()
    central.connect(peripheral)
  }
  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard central === self.central, peripheral === self.peripheral, let identifiers else { return }
    SetupLog.bluetooth.info("connected; discovering services")
    peripheral.discoverServices([CBUUID(string: identifiers.service)])
  }
  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
    error: (any Error)?
  ) {
    guard central === self.central, peripheral === self.peripheral else { return }
    SetupLog.bluetooth.error("connect failed: \(Self.describe(error), privacy: .public)")
    event?(.unavailable)
  }
  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
    error: (any Error)?
  ) {
    guard central === self.central, peripheral === self.peripheral else { return }
    SetupLog.bluetooth.error(
      "the link was closed by \(Self.closer(error), privacy: .public): \(Self.describe(error), privacy: .public)"
    )
    event?(.disconnected)
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
    guard peripheral === self.peripheral, let identifiers else { return }
    let services =
      peripheral.services?.filter { $0.uuid == CBUUID(string: identifiers.service) } ?? []
    guard error == nil, services.count == 1, let service = services.first else {
      SetupLog.bluetooth.error(
        "service discovery: \(services.count, privacy: .public) KM43 services, \(Self.describe(error), privacy: .public)"
      )
      event?(.unavailable)
      return
    }
    peripheral.discoverCharacteristics(
      [CBUUID(string: identifiers.rx), CBUUID(string: identifiers.tx)], for: service)
  }
  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
    error: (any Error)?
  ) {
    guard peripheral === self.peripheral, let identifiers,
      service.uuid == CBUUID(string: identifiers.service)
    else { return }
    guard error == nil else {
      SetupLog.bluetooth.error(
        "characteristic discovery: \(Self.describe(error), privacy: .public)")
      event?(.unavailable)
      return
    }
    let rxMatches =
      service.characteristics?.filter { $0.uuid == CBUUID(string: identifiers.rx) } ?? []
    let txMatches =
      service.characteristics?.filter { $0.uuid == CBUUID(string: identifiers.tx) } ?? []
    rx = rxMatches.first
    tx = txMatches.first
    event?(
      .profile(
        BluetoothProfile(
          serviceCount: 1, rxCount: rxMatches.count, txCount: txMatches.count,
          rxWritesWithoutResponse: rx?.properties.contains(.writeWithoutResponse) ?? false,
          txNotifies: tx?.properties.contains(.notify) ?? false)))
  }
  func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    guard peripheral === self.peripheral, characteristic === tx else { return }
    guard error == nil, characteristic.isNotifying else {
      SetupLog.bluetooth.error("notify subscription: \(Self.describe(error), privacy: .public)")
      event?(.unavailable)
      return
    }
    SetupLog.bluetooth.info(
      "subscribed; ATT payload \(peripheral.maximumWriteValueLength(for: .withoutResponse), privacy: .public) bytes without response, \(peripheral.maximumWriteValueLength(for: .withResponse), privacy: .public) with"
    )
    event?(.subscribed)
  }
  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    guard peripheral === self.peripheral, characteristic === tx else { return }
    guard error == nil, let value = characteristic.value else {
      SetupLog.bluetooth.error("notification: \(Self.describe(error), privacy: .public)")
      event?(.disconnected)
      return
    }
    event?(.value(value))
  }
  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    guard peripheral === self.peripheral else { return }
    event?(.writable)
  }

  /// Which side ended the link, from the disconnect error CoreBluetooth
  /// reports. `nil` answers the app's own cancel.
  private static func closer(_ error: (any Error)?) -> String {
    guard let error else { return "this app" }
    let code = (error as? CBError)?.code
    if code == .peripheralDisconnected { return "the controller" }
    if code == .connectionTimeout { return "the radio link (supervision timeout)" }
    return "an unclassified cause"
  }

  /// A CoreBluetooth error as its domain and code.
  private static func describe(_ error: (any Error)?) -> String {
    guard let error = error as NSError? else { return "no error" }
    return "\(error.domain) \(error.code)"
  }
}
