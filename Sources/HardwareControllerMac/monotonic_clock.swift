import Darwin.Mach
import Foundation

public enum MonotonicClock {
  private static let timebase: mach_timebase_info_data_t = {
    var value = mach_timebase_info_data_t()
    mach_timebase_info(&value)
    return value
  }()

  public static func nowNanoseconds() -> UInt64 {
    nanoseconds(fromAbsoluteTicks: mach_absolute_time())
  }

  public static func nanoseconds(
    fromAbsoluteTicks ticks: UInt64
  ) -> UInt64 {
    UInt64(
      (Double(ticks) * Double(timebase.numer))
        / Double(timebase.denom)
    )
  }
}
