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
      event?(.disconnected)
      return
    }
    peripheral.writeValue(value, for: rx, type: .withoutResponse)
  }
  func disconnect() {
    central?.stopScan()
    if let peripheral {
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
    switch central.state {
    case .poweredOn:
      if peripheral == nil {
        central.scanForPeripherals(withServices: [CBUUID(string: identifiers.service)])
      }
    case .unknown, .resetting: break
    case .poweredOff, .unauthorized, .unsupported: event?(.unavailable)
    @unknown default: event?(.unavailable)
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
    self.peripheral = peripheral
    peripheral.delegate = self
    central.stopScan()
    central.connect(peripheral)
  }
  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard central === self.central, peripheral === self.peripheral, let identifiers else { return }
    peripheral.discoverServices([CBUUID(string: identifiers.service)])
  }
  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
    error: (any Error)?
  ) {
    guard central === self.central, peripheral === self.peripheral else { return }
    event?(.unavailable)
  }
  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
    error: (any Error)?
  ) {
    guard central === self.central, peripheral === self.peripheral else { return }
    event?(.disconnected)
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
    guard peripheral === self.peripheral, let identifiers else { return }
    let services =
      peripheral.services?.filter { $0.uuid == CBUUID(string: identifiers.service) } ?? []
    guard error == nil, services.count == 1, let service = services.first else {
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
      event?(.unavailable)
      return
    }
    event?(.subscribed)
  }
  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
    error: (any Error)?
  ) {
    guard peripheral === self.peripheral, characteristic === tx else { return }
    guard error == nil, let value = characteristic.value else {
      event?(.disconnected)
      return
    }
    event?(.value(value))
  }
  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    guard peripheral === self.peripheral else { return }
    event?(.writable)
  }
}
