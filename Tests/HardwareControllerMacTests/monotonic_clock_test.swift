import Darwin.Mach
import Testing

@testable import HardwareControllerMac

struct MonotonicClockTest {
  @Test
  func convertsTicksWithTheHostTimebase() {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = UInt64(timebase.denom) * 1_000

    #expect(MonotonicClock.nanoseconds(fromAbsoluteTicks: 0) == 0)
    #expect(
      MonotonicClock.nanoseconds(fromAbsoluteTicks: ticks)
        == UInt64(timebase.numer) * 1_000
    )
  }

  @Test
  func readingsNeverDecrease() {
    let first = MonotonicClock.nowNanoseconds()
    let second = MonotonicClock.nowNanoseconds()

    #expect(second >= first)
  }
}
