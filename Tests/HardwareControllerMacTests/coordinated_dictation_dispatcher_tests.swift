import Testing

@testable import HardwareControllerMac

struct CoordinatedDictationDispatcherTests {
  @Test
  func switchingWorkflowsCancelsTheOtherBeforeBeginning() async {
    let recorder = CoordinatedCommandRecorder()
    let dispatchers = CoordinatedDictationDispatchers(
      localHandler: { command in
        await recorder.append(.local, command)
      },
      localAIHandler: { command in
        await recorder.append(.localAI, command)
      }
    )

    #expect(dispatchers.local.submit(.begin))
    #expect(dispatchers.localAI.submit(.begin))
    #expect(dispatchers.localAI.submit(.finish))
    await dispatchers.local.shutdownAndWait()

    #expect(
      await recorder.events == [
        .init(workflow: .localAI, command: .cancel),
        .init(workflow: .local, command: .begin),
        .init(workflow: .local, command: .cancel),
        .init(workflow: .localAI, command: .begin),
        .init(workflow: .localAI, command: .finish),
        .init(workflow: .local, command: .cancel),
        .init(workflow: .localAI, command: .cancel),
      ]
    )
    #expect(!dispatchers.localAI.submit(.begin))
  }
}

private actor CoordinatedCommandRecorder {
  struct Event: Equatable, Sendable {
    let workflow: DictationWorkflow
    let command: DictationCommand
  }

  private(set) var events: [Event] = []

  func append(
    _ workflow: DictationWorkflow,
    _ command: DictationCommand
  ) {
    events.append(Event(workflow: workflow, command: command))
  }
}
