import Testing

@testable import SetupKit

private let held = NetworkSettings(
  version: 3, ssid: "home", passphraseSet: true, country: "CA", hostname: "unit")
private let blank = NetworkSettings(
  version: 0, ssid: nil, passphraseSet: false, country: nil, hostname: nil)

// MARK: Suggestions

@Test func controllerAndPhoneNetworksAreListedControllerFirst() {
  #expect(
    NetworkSuggestion.list(controller: "home", phone: "office") == [
      NetworkSuggestion(ssid: "home", onController: true, onPhone: false),
      NetworkSuggestion(ssid: "office", onController: false, onPhone: true),
    ])
}

@Test func theSameNetworkOnBothIsOneRow() {
  #expect(
    NetworkSuggestion.list(controller: "home", phone: "home") == [
      NetworkSuggestion(ssid: "home", onController: true, onPhone: true)
    ])
}

@Test func noKnownNetworkListsNothing() {
  #expect(NetworkSuggestion.list(controller: nil, phone: nil).isEmpty)
  #expect(NetworkSuggestion.list(controller: "", phone: "").isEmpty)
}

@Test func namesThatDifferInBytesStaySeparate() {
  // "é" precomposed and decomposed are equal Strings but different SSIDs.
  let list = NetworkSuggestion.list(controller: "caf\u{E9}", phone: "cafe\u{301}")
  #expect(list.count == 2)
  #expect(list.map(\.onPhone) == [false, true])
  #expect(list[0].id != list[1].id)
}

// MARK: Defaults

@Test func draftKeepsTheControllersCountryAndHostname() {
  let draft = NetworkDraft(ssid: "office", settings: held, region: "FR")
  #expect(draft == NetworkDraft(ssid: "office", country: "CA", hostname: "unit"))
}

@Test func unsetCountryTakesAValidPhoneRegion() {
  #expect(NetworkDraft(ssid: "office", settings: blank, region: "FR").country == "FR")
  #expect(NetworkDraft(ssid: "office", settings: blank, region: "419").country == "")
  #expect(NetworkDraft(ssid: "office", settings: blank, region: nil).country == "")
  #expect(NetworkDraft(ssid: "office", settings: blank, region: "FR").hostname == "")
}

// MARK: Passphrase

@Test func sameNetworkKeepsTheHeldPassphrase() {
  let draft = NetworkDraft(ssid: "home", country: "CA", hostname: "unit")
  #expect(draft.problem(against: held) == nil)
  #expect(
    draft.change == NetworkChange(ssid: "home", passphrase: nil, country: "CA", hostname: "unit"))
}

@Test func anotherNetworkNeedsAPassphrase() {
  var draft = NetworkDraft(ssid: "office", country: "CA", hostname: "unit")
  #expect(draft.problem(against: held) == .passphraseRequired(ssid: "office"))
  draft.passphrase = "correct horse"
  #expect(draft.problem(against: held) == nil)
  #expect(draft.change.passphrase == "correct horse")
}

@Test func aNormalisedButDifferentSSIDCannotKeepThePassphrase() {
  let settings = NetworkSettings(
    version: 3, ssid: "caf\u{E9}", passphraseSet: true, country: "CA", hostname: "unit")
  let draft = NetworkDraft(ssid: "cafe\u{301}", country: "CA", hostname: "unit")
  #expect(!draft.canKeepPassphrase(settings))
}

@Test func passphraseLengthBounds() {
  var draft = NetworkDraft(ssid: "office", country: "CA", hostname: "unit")
  for (length, ok) in [(7, false), (8, true), (63, true), (64, false)] {
    draft.passphrase = String(repeating: "a", count: length)
    #expect((draft.problem(against: held) == nil) == ok, "length \(length)")
  }
}

@Test func networkNameIsAtMost32Bytes() {
  var draft = NetworkDraft(
    ssid: String(repeating: "n", count: 32), passphrase: "password", country: "CA",
    hostname: "unit")
  #expect(draft.problem(against: held) == nil)
  draft.ssid = String(repeating: "\u{E9}", count: 17)  // 34 bytes, 17 characters
  #expect(draft.problem(against: held) == .networkNameTooLong)
}

// MARK: Forgetting

@Test func noSSIDForgetsTheNetwork() {
  let draft = NetworkDraft(ssid: nil, country: "CA", hostname: "unit")
  #expect(draft.problem(against: held) == nil)
  #expect(
    draft.change == NetworkChange(ssid: nil, passphrase: nil, country: "CA", hostname: "unit"))
  #expect(draft.change.isValid(comparedTo: held))
}

@Test func forgettingRefusesAPassphrase() {
  let draft = NetworkDraft(ssid: nil, passphrase: "password", country: "CA", hostname: "unit")
  #expect(draft.problem(against: held) == .passphraseWithoutNetwork)
}

@Test func anUntypedNameIsRequiredNotAForget() {
  // Other network with nothing typed must never clear the held network.
  let draft = NetworkDraft(ssid: "", country: "CA", hostname: "unit")
  #expect(draft.problem(against: held) == .networkNameRequired)
  #expect(!draft.canKeepPassphrase(held))
  #expect(!NetworkDraftProblem.networkNameRequired.isAdvanced)
}

// MARK: Advanced fields

@Test func countryIsTwoCapitalLetters() {
  for (country, ok) in [("CA", true), ("ca", false), ("C", false), ("CAN", false), ("", false)] {
    let draft = NetworkDraft(ssid: "home", country: country, hostname: "unit")
    #expect((draft.problem(against: held) == nil) == ok, "\(country)")
  }
  #expect(NetworkDraftProblem.country.isAdvanced)
}

@Test func hostnameRules() {
  let cases: [(String, Bool)] = [
    ("unit-1", true), (String(repeating: "h", count: 32), true), ("", false),
    (String(repeating: "h", count: 33), false), ("-unit", false), ("unit-", false),
    ("my_unit", false), ("unit.local", false),
  ]
  for (hostname, ok) in cases {
    let draft = NetworkDraft(ssid: "home", country: "CA", hostname: hostname)
    #expect((draft.problem(against: held) == nil) == ok, "\(hostname)")
  }
  #expect(NetworkDraftProblem.hostname.isAdvanced)
  #expect(!NetworkDraftProblem.passphraseLength.isAdvanced)
}

@Test func networkProblemsComeBeforeAdvancedOnes() {
  let draft = NetworkDraft(ssid: "office", country: "", hostname: "")
  #expect(draft.problem(against: held) == .passphraseRequired(ssid: "office"))
}

@Test func aNeverWrittenControllerNeedsTheAdvancedFields() {
  #expect(NetworkDraft(ssid: "office", settings: blank, region: nil).advancedProblem == .country)
  #expect(NetworkDraft(ssid: "office", settings: blank, region: "CA").advancedProblem == .hostname)
  #expect(NetworkDraft(ssid: "office", settings: held, region: nil).advancedProblem == nil)
}
