import Foundation
import Testing

@testable import SetupKit

/// Reads the first byte as the epoch and the rest as the `device_id`; a
/// zero epoch or no bytes do not decode.
struct ByteGenerationReader: GenerationReader {
  func generation(of enrolment: Data) -> ControllerGeneration? {
    guard let epoch = enrolment.first, epoch != 0 else { return nil }
    return ControllerGeneration(
      deviceID: String(decoding: enrolment.dropFirst(), as: UTF8.self), epoch: UInt32(epoch))
  }
}

private func kept(_ deviceID: String, epoch: UInt8) -> Data { Data([epoch]) + Data(deviceID.utf8) }

@Test func everyKeptEnrolmentNamesItsGeneration() {
  let store = MemoryEnrolmentStore(["b": kept("b", epoch: 2), "a": kept("a", epoch: 5)])
  #expect(
    store.generations(reader: ByteGenerationReader()) == [
      ControllerGeneration(deviceID: "a", epoch: 5), ControllerGeneration(deviceID: "b", epoch: 2),
    ])
}

@Test func nothingKeptNamesNoGeneration() {
  #expect(MemoryEnrolmentStore().generations(reader: ByteGenerationReader()).isEmpty)
  #expect(NoEnrolmentStore().generations(reader: ByteGenerationReader()).isEmpty)
}

@Test func unreadableOrMisfiledEnrolmentsAreLeftOut() {
  let store = MemoryEnrolmentStore([
    "a": kept("a", epoch: 1),
    "b": kept("b", epoch: 0),
    "c": Data(),
    "d": kept("e", epoch: 3),
  ])
  #expect(
    store.generations(reader: ByteGenerationReader()) == [
      ControllerGeneration(deviceID: "a", epoch: 1)
    ])
}

@Test func anAccountListsItsOwnAndSignedOutControllersOnce() {
  let own = MemoryEnrolmentStore(["a": kept("a", epoch: 4), "b": kept("b", epoch: 1)])
  let signedOut = MemoryEnrolmentStore(["a": kept("a", epoch: 2), "c": kept("c", epoch: 7)])
  let store = AccountEnrolmentStore(own: own, signedOut: signedOut)
  #expect(store.deviceIDs() == ["a", "b", "c"])
  // The account's own enrolment wins, as it does when setup loads one.
  #expect(
    store.generations(reader: ByteGenerationReader()) == [
      ControllerGeneration(deviceID: "a", epoch: 4), ControllerGeneration(deviceID: "b", epoch: 1),
      ControllerGeneration(deviceID: "c", epoch: 7),
    ])
}
