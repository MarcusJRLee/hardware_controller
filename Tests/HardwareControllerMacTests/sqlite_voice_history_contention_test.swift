import Testing

@testable import HardwareControllerMac

struct SQLiteVoiceHistoryContentionTest {
  /// The schedule matches `sqlite3_busy_timeout`, including its 100 ms tail.
  @Test
  func backoffFollowsSQLiteSchedule() throws {
    let first = try #require(SQLiteVoiceHistoryContention.backoff(attempt: 0))
    #expect(first == (0, 1))
    let tail = try #require(SQLiteVoiceHistoryContention.backoff(attempt: 11))
    #expect(tail == (228, 100))
    let later = try #require(SQLiteVoiceHistoryContention.backoff(attempt: 12))
    #expect(later == (328, 100))
  }

  /// Every retry together sleeps exactly the bound, then the wait gives up.
  @Test
  func backoffSpendsExactlyTheBound() {
    var attempt = 0
    var slept = 0
    while let backoff = SQLiteVoiceHistoryContention.backoff(attempt: attempt) {
      #expect(backoff.waitedMilliseconds == slept)
      slept += backoff.delayMilliseconds
      attempt += 1
    }
    #expect(slept == SQLiteVoiceHistoryContention.timeoutMilliseconds)
    #expect(SQLiteVoiceHistoryContention.backoff(attempt: Int(Int32.max)) == nil)
    #expect(SQLiteVoiceHistoryContention.backoff(attempt: -1) == nil)
  }

  /// The last retry sleeps only what remains, and a spent bound never waits.
  @Test
  func backoffTrimsTheLastDelayToTheBound() throws {
    let trimmed = try #require(
      SQLiteVoiceHistoryContention.backoff(attempt: 3, timeoutMilliseconds: 10)
    )
    #expect(trimmed == (8, 2))
    #expect(SQLiteVoiceHistoryContention.backoff(attempt: 4, timeoutMilliseconds: 10) == nil)
    #expect(SQLiteVoiceHistoryContention.backoff(attempt: 0, timeoutMilliseconds: 0) == nil)
  }
}
