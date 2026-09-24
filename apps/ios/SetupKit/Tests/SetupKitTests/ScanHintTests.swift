import Testing

@testable import SetupKit

/// A clock reading the tests set by hand.
private struct Tick: InstantProtocol {
  var offset: Duration

  static func at(_ seconds: Double) -> Tick { Tick(offset: .seconds(seconds)) }
  func advanced(by duration: Duration) -> Tick { Tick(offset: offset + duration) }
  func duration(to other: Tick) -> Duration { other.offset - offset }
  static func < (lhs: Tick, rhs: Tick) -> Bool { lhs.offset < rhs.offset }
}

@Test func showsOnlyOnceTheDelayHasPassedSinceTheScanStarted() {
  var hint = ScanHint<Tick>()
  hint.scanStarted(at: .at(10))
  #expect(hint.deadline == .at(18))
  #expect(!hint.isVisible(at: .at(10)))
  #expect(!hint.isVisible(at: .at(17.999)))
  #expect(hint.isVisible(at: .at(18)))
  #expect(hint.isVisible(at: .at(60)))
}

@Test func staysHiddenBeforeAnyScanStarts() {
  let hint = ScanHint<Tick>()
  #expect(hint.deadline == nil)
  #expect(!hint.isVisible(at: .at(1_000)))
}

@Test func aRescanRestartsTheWaitAndHidesAShownHint() {
  var hint = ScanHint<Tick>(delay: .seconds(8))
  hint.scanStarted(at: .at(0))
  #expect(hint.isVisible(at: .at(9)))
  hint.scanStarted(at: .at(9))
  #expect(!hint.isVisible(at: .at(9)))
  #expect(!hint.isVisible(at: .at(16.5)))
  #expect(hint.isVisible(at: .at(17)))
}

@Test func aDismissedHintStaysHiddenAcrossRescans() {
  var hint = ScanHint<Tick>()
  hint.scanStarted(at: .at(0))
  hint.dismiss()
  #expect(hint.deadline == nil)
  #expect(!hint.isVisible(at: .at(9)))
  hint.scanStarted(at: .at(20))
  #expect(!hint.isVisible(at: .at(100)))
}

@Test func stoppingTheScanCancelsThePendingHint() {
  var hint = ScanHint<Tick>()
  hint.scanStarted(at: .at(0))
  hint.scanStopped()
  #expect(hint.deadline == nil)
  #expect(!hint.isVisible(at: .at(9)))
  hint.scanStarted(at: .at(30))
  #expect(hint.isVisible(at: .at(38)))
}
