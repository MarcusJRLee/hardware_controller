import Testing

@testable import HardwareControllerMac

struct DictationCommandDispatcherTests {
  @Test
  func awaitedShutdownHandlesEveryCommandInOrder() async {
    let recorder = AsyncCommandRecorder()
    let dispatcher = AsyncDictationCommandDispatcher(
      handler: { command in
        await recorder.append(command)
      },
      onShutdown: {
        await recorder.markShutdown()
      }
    )

    #expect(dispatcher.submit(.begin))
    #expect(dispatcher.submit(.finish))
    await dispatcher.shutdownAndWait()

    #expect(await recorder.commands == [.begin, .finish, .cancel])
    #expect(await recorder.didShutDown)
    #expect(!dispatcher.submit(.begin))
  }
}

private actor AsyncCommandRecorder {
  private(set) var commands: [DictationCommand] = []
  private(set) var didShutDown = false

  func append(_ command: DictationCommand) {
    commands.append(command)
  }

  func markShutdown() {
    didShutDown = true
  }
}
