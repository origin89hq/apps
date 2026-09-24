import Testing

@testable import SetupKit

@Test func suffixIsEightZeroPaddedHexDigits() {
  #expect(EnrolmentLabel.suffix(0) == "00000000")
  #expect(EnrolmentLabel.suffix(0xAB) == "000000AB")
  #expect(EnrolmentLabel.suffix(0x1234_5678) == "12345678")
  #expect(EnrolmentLabel.suffix(.max) == "FFFFFFFF")
}

@Test func longestModelLabelFitsTheControllerLimit() {
  let label = EnrolmentLabel.label(model: "iPod touch", suffix: EnrolmentLabel.suffix(.max))
  #expect(label == "iPod touch FFFFFFFF")
  #expect(label.utf8.count == 19)
  #expect(label.utf8.count <= 32)
}

@Test func storedShortSuffixIsKeptAsIs() {
  #expect(EnrolmentLabel.label(model: "iPad", suffix: "3F2") == "iPad 3F2")
}
