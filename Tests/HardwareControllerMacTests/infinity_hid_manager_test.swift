import IOKit
import Testing

@testable import HardwareControllerMac

struct InfinityHIDManagerTest {
  @Test
  func startOpensExclusivelyBeforeActivation() {
    let recorder = HIDOperationRecorder(openResult: kIOReturnSuccess)
    let source = makeSource(operations: recorder.operations)

    let result = source.start()

    #expect(result == .started)
    #expect(
      recorder.calls == [
        .open(IOOptionBits(kIOHIDOptionsTypeSeizeDevice)),
        .setDispatchQueue,
        .setCancelHandler,
        .activate,
      ]
    )

    source.stop()

    #expect(
      recorder.calls.suffix(2) == [
        .close(IOOptionBits(kIOHIDOptionsTypeNone)),
        .cancel,
      ]
    )
  }

  @Test
  func exclusiveAccessFailureDoesNotActivate() {
    let recorder = HIDOperationRecorder(
      openResult: kIOReturnExclusiveAccess
    )
    let source = makeSource(operations: recorder.operations)

    let result = source.start()

    #expect(result == .failed(.exclusiveAccess))
    #expect(
      recorder.calls == [
        .open(IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
      ]
    )
  }

  @Test
  func permissionFailureIsActionable() {
    let recorder = HIDOperationRecorder(
      openResult: kIOReturnNotPermitted
    )
    let source = makeSource(operations: recorder.operations)

    #expect(source.start() == .failed(.notPermitted))
  }

  private func makeSource(
    operations: HIDManagerOperations
  ) -> InfinityHIDManager {
    InfinityHIDManager(
      queue: DispatchQueue(label: "hid-manager-tests"),
      onConnect: { _ in },
      onDisconnect: { _ in },
      onEvent: { _ in },
      operations: operations
    )
  }
}

private final class HIDOperationRecorder: @unchecked Sendable {
  enum Call: Equatable {
    case open(IOOptionBits)
    case setDispatchQueue
    case setCancelHandler
    case activate
    case close(IOOptionBits)
    case cancel
  }

  private(set) var calls: [Call] = []
  private var cancelHandler: (@Sendable () -> Void)?
  private let openResult: IOReturn

  init(openResult: IOReturn) {
    self.openResult = openResult
  }

  var operations: HIDManagerOperations {
    HIDManagerOperations(
      open: { [self] _, options in
        calls.append(.open(options))
        return openResult
      },
      close: { [self] _, options in
        calls.append(.close(options))
        return kIOReturnSuccess
      },
      setDispatchQueue: { [self] _, _ in
        calls.append(.setDispatchQueue)
      },
      setCancelHandler: { [self] _, handler in
        calls.append(.setCancelHandler)
        cancelHandler = handler
      },
      activate: { [self] _ in
        calls.append(.activate)
      },
      cancel: { [self] _ in
        calls.append(.cancel)
        cancelHandler?()
      }
    )
  }
}
