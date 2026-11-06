import Testing

@testable import HardwareControllerCore

struct SpokenNumberParserTests {
  @Test(
    arguments: [
      ("44", "44", 1),
      ("forty four", "44", 2),
      ("Forty four and more", "44", 2),
      ("seven", "7", 1),
      ("twelve", "12", 1),
      ("one two three", "123", 3),
      ("zero", "0", 1),
      ("one hundred two", "102", 3),
      ("one hundred and two", "102", 4),
      ("fifteen hundred", "1500", 2),
      ("two thousand and twenty six", "2026", 5),
      ("one million two thousand three", "1002003", 5),
      ("twenty five six", "25", 2),
      ("one thousand and", "1000", 2),
    ]
  )
  func parsesTheLongestNumberPrefix(
    spoken: String,
    digits: String,
    consumed: Int
  ) {
    let tokens = spoken.split(separator: " ").map(String.init)

    #expect(
      SpokenNumberParser().parsePrefix(tokens)
        == SpokenNumber(digits: digits, consumedTokenCount: consumed)
    )
  }

  @Test(arguments: [[], [""], ["and"], ["hundred"], ["issue"]])
  func rejectsTokensThatDoNotStartANumber(tokens: [String]) {
    #expect(SpokenNumberParser().parsePrefix(tokens) == nil)
  }
}
