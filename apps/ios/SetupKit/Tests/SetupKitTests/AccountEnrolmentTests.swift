import Foundation
import Testing

@testable import SetupKit

private let deviceID = KeptClient.deviceID
private let signedOutPairing = Data([0x01, 0x10])
private let accountPairing = Data([0x01, 0x20])
private let otherPairing = Data([0x01, 0x30])

@Test func anAccountSeesItsOwnPairingBeforeTheSignedOutOne() throws {
  let own = MemoryEnrolmentStore([deviceID: accountPairing])
  let signedOut = MemoryEnrolmentStore([deviceID: signedOutPairing, "beef": signedOutPairing])
  let store = AccountEnrolmentStore(own: own, signedOut: signedOut)
  #expect(store.load(deviceID: deviceID) == accountPairing)
  #expect(store.load(deviceID: "beef") == signedOutPairing)
  #expect(store.load(deviceID: "none") == nil)
}

@Test func aPairingWhileSignedInIsKeptForTheAccountOnly() throws {
  let own = MemoryEnrolmentStore()
  let signedOut = MemoryEnrolmentStore([deviceID: signedOutPairing])
  try AccountEnrolmentStore(own: own, signedOut: signedOut).save(accountPairing, deviceID: deviceID)
  #expect(own[deviceID] == accountPairing)
  #expect(signedOut[deviceID] == signedOutPairing)
}

/// Forgetting removes what the account sees; another account's pairing stays.
@Test func forgettingLeavesOtherAccountsAlone() throws {
  let own = MemoryEnrolmentStore([deviceID: accountPairing, "beef": accountPairing])
  let signedOut = MemoryEnrolmentStore([deviceID: signedOutPairing])
  let other = MemoryEnrolmentStore([deviceID: otherPairing])
  let store = AccountEnrolmentStore(own: own, signedOut: signedOut)
  try store.remove(deviceID: deviceID)
  #expect(own[deviceID] == nil)
  #expect(own["beef"] == accountPairing)
  #expect(signedOut.isEmpty)
  try store.removeAll()
  #expect(own.isEmpty)
  #expect(other[deviceID] == otherPairing)
}

/// A removal that fails in one store still runs in the other, then throws.
@Test func aFailedRemovalStillRemovesTheRest() {
  let own = MemoryEnrolmentStore([deviceID: accountPairing], refusesRemovals: true)
  let signedOut = MemoryEnrolmentStore([deviceID: signedOutPairing])
  let store = AccountEnrolmentStore(own: own, signedOut: signedOut)
  #expect(throws: MemoryEnrolmentStore.Refused.self) { try store.remove(deviceID: deviceID) }
  #expect(signedOut.isEmpty)
  #expect(own[deviceID] == accountPairing)
}

private actor IdleTransport: FrameTransport {
  func open() async throws(TransportError) {}
  func send(_ frame: Data) async throws(TransportError) {}
  func receive() async throws(TransportError) -> Data { Data() }
  func close() async {}
}

private struct ResumingFactory: ControllerClientFactory {
  func client(setupCode: String, transport: any FrameTransport) throws(SetupCodeError)
    -> any ControllerClient
  { KeptClient(.accepts) }
  func client(
    resuming deviceID: String, from store: any EnrolmentStore, transport: any FrameTransport
  ) -> (any ControllerClient)? {
    store.load(deviceID: deviceID).map { KeptClient(.accepts, resuming: $0) }
  }
}

@MainActor private func launch(_ store: any EnrolmentStore, _ last: MemoryLastController)
  -> SetupFlow
{
  let transport = IdleTransport()
  return SetupFlow(
    factory: ResumingFactory(), store: store, transportFactory: { transport },
    lastController: last)
}

/// The acceptance's sign-out case: a pairing made under an account is hidden
/// once it signs out and back when it signs in; nothing is removed or changed.
@Test @MainActor func signingOutAndBackKeepsTheAccountsPairing() async throws {
  let own = MemoryEnrolmentStore()
  let signedOut = MemoryEnrolmentStore()
  let accountLast = MemoryLastController()
  let signedOutLast = MemoryLastController()
  let accountStore = AccountEnrolmentStore(own: own, signedOut: signedOut)

  let paired = launch(accountStore, accountLast)
  try paired.submitCode("valid")
  await paired.connect()
  await paired.confirmWindowOpened()
  #expect(own[deviceID] == KeptClient.paired)
  #expect(accountLast.load() == deviceID)
  await paired.suspend()

  // Signed out: the account's pairing is not offered.
  let hidden = launch(signedOut, signedOutLast)
  #expect(hidden.state == .enterCode)
  #expect(signedOut.isEmpty)
  #expect(own[deviceID] == KeptClient.paired)

  // Signed in again: the relaunch reconnects from the account's pairing.
  let back = launch(accountStore, accountLast)
  #expect(back.state == .connecting)
  #expect(back.resumed)
  #expect(back.knownController == deviceID)
}

/// Pairings made while signed out are the phone's: every account uses them.
@Test @MainActor func anAccountUsesAPairingMadeSignedOut() async throws {
  let signedOut = MemoryEnrolmentStore([deviceID: signedOutPairing])
  let flow = launch(
    AccountEnrolmentStore(own: MemoryEnrolmentStore(), signedOut: signedOut),
    MemoryLastController(deviceID))
  #expect(flow.state == .connecting)
  #expect(flow.resumed)
}
