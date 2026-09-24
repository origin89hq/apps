import Testing

@testable import SetupKit

private let code =
  "km43:1:" + String(repeating: "a", count: 32) + ":" + String(repeating: "b", count: 64)

@Test func firstCodePassesOnceAndRepeatsAreDropped() {
  var gate = ScanGate()
  #expect(gate.pass(code) == code)
  #expect(gate.pass(code) == nil)
  #expect(gate.pass("km43:1:other") == nil)
  #expect(!gate.isOpen)
}

@Test func emptyAndMissingStringsAreIgnoredWithoutClosingTheGate() {
  var gate = ScanGate()
  #expect(gate.pass(nil) == nil)
  #expect(gate.pass("") == nil)
  #expect(gate.isOpen)
  #expect(gate.pass(code) == code)
}

@Test func anyNonEmptyStringPassesSoTheParserDecides() {
  var gate = ScanGate()
  #expect(gate.pass("https://example.com") == "https://example.com")
}

@Test func rearmAfterARefusedCodeLetsTheNextScanThrough() {
  var gate = ScanGate()
  #expect(gate.pass("not a setup code") == "not a setup code")
  #expect(gate.pass(code) == nil)
  gate.rearm()
  #expect(gate.pass(code) == code)
  #expect(gate.pass(code) == nil)
}
