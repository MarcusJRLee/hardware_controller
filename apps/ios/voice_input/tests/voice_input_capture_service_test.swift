import Foundation
import Synchronization
import VoiceInputShared
import XCTest

@testable import VoiceInput

final class VoiceInputCaptureServiceTest: XCTestCase {
  func testActivationReconcilesOrphanedOwnershipWithoutDeletingPartialAudio() async throws {
    let sessionID = UUID()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let partial = root.appendingPathComponent(
      "\(sessionID.uuidString.lowercased()).partial"
    )
    try Data("recover-me".utf8).write(to: partial)
    let store = LockedProbeStore(
      command: nil,
      snapshot: .recording(
        sessionID: sessionID,
        sequence: 7,
        heartbeatAt: Date(timeIntervalSince1970: 10)
      )
    )
    let activityManager = RecordingLiveActivityManager(startedID: nil)
    let service = VoiceInputCaptureService(
      store: store,
      captureDirectoryURL: root,
      activityManager: activityManager
    )

    try await service.reconcileOnActivation()

    let snapshot = try store.readSnapshot()
    XCTAssertEqual(snapshot.phase, .interrupted)
    XCTAssertEqual(snapshot.sessionID, sessionID)
    XCTAssertEqual(snapshot.sequence, 8)
    XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    let orphanReconciliationCount = await activityManager.orphanReconciliationCount
    XCTAssertEqual(orphanReconciliationCount, 1)
  }

  func testCapturePhaseChangesReloadTheSystemControlWithoutHeartbeatChurn() async throws {
    let reloadCount = Mutex(0)
    let fixture = try CaptureFixture(
      liveActivityID: "activity",
      controlReloader: { reloadCount.withLock { $0 += 1 } },
      heartbeatInterval: .seconds(60)
    )
    addTeardownBlock { try fixture.remove() }

    try await fixture.service.start(sessionID: UUID())
    do {
      try await fixture.service.stop(styleKind: .natural)
      XCTFail("The fixture finalizer must fail after entering Transcribing.")
    } catch {
      XCTAssertEqual(error as? CaptureServiceTestError, .unused)
    }

    XCTAssertEqual(reloadCount.withLock { $0 }, 2)
  }

  func testExactSystemStopCommandFinalizesTheOwnedSession() async throws {
    let fixture = try CaptureFixture(liveActivityID: "activity")
    addTeardownBlock { try fixture.remove() }
    let sessionID = UUID()
    try await fixture.service.start(sessionID: sessionID)
    try fixture.store.writeCommand(
      .stop(sessionID: sessionID, styleKind: .natural, issuedAt: .now)
    )

    do {
      try await fixture.service.processPendingCommand()
      XCTFail("The fixture transcriber must fail after the stop is accepted.")
    } catch {
      XCTAssertEqual(error as? CaptureServiceTestError, .unused)
    }

    XCTAssertNil(try fixture.store.readCommand())
    XCTAssertEqual(fixture.recorderFactory.stopCount, 1)
    XCTAssertEqual(try fixture.store.readSnapshot().phase, .failed)
    XCTAssertEqual(
      fixture.recoveryStore.calls.map(\.sessionID),
      [sessionID]
    )
  }

  func testStaleStartCommandIsConsumedWithoutStartingCapture() async throws {
    let store = LockedProbeStore(
      command: .start(
        sessionID: UUID(),
        issuedAt: Date(timeIntervalSinceNow: -60)
      )
    )
    let captureDirectoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let service = VoiceInputCaptureService(
      store: store,
      captureDirectoryURL: captureDirectoryURL
    )

    try await service.processPendingCommand()

    XCTAssertNil(try store.readCommand())
    XCTAssertEqual(try store.readSnapshot(), .idle(sequence: 0))
    XCTAssertFalse(FileManager.default.fileExists(atPath: captureDirectoryURL.path))
  }

  func testStartReservesCaptureOwnershipWhileTheModelPrewarms() async throws {
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let provider = BlockingASRModelProvider(
      entered: entered.continuation,
      release: release.stream
    )
    let workflow = VoiceInputASRWorkflow(
      modelProvider: provider,
      transcriber: UnusedTranscriber()
    )
    let store = LockedProbeStore(command: nil)
    let service = VoiceInputCaptureService(
      store: store,
      captureDirectoryURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true),
      asrWorkflow: workflow,
      sessionFinalizer: VoiceInputSessionFinalizer(
        history: UnusedHistoryStore()
      )
    )
    let firstSessionID = UUID()
    let firstStart = Task {
      try await service.start(sessionID: firstSessionID)
    }
    for await _ in entered.stream.prefix(1) {}

    do {
      try await service.start(sessionID: UUID())
      XCTFail("A second start must not enter model preparation.")
    } catch {
      XCTAssertEqual(error as? VoiceInputCaptureError, .alreadyRecording)
    }

    release.continuation.finish()
    do {
      try await firstStart.value
      XCTFail("The released test prewarm must fail.")
    } catch {
      XCTAssertEqual(error as? CaptureServiceTestError, .released)
    }
    let providerCallCount = await provider.callCount
    XCTAssertEqual(providerCallCount, 1)
    XCTAssertEqual(try store.readSnapshot().sessionID, firstSessionID)
    XCTAssertEqual(try store.readSnapshot().phase, .failed)
  }

  func testAudioInterruptionPreservesPartialHistoryBeforeReleasingCapture() async throws {
    let fixture = try CaptureFixture(liveActivityID: "activity")
    addTeardownBlock { try fixture.remove() }
    let sessionID = UUID()

    try await fixture.service.start(sessionID: sessionID)
    let decision = await fixture.service.handleLifecycleEvent(
      .audioInterruptionBegan
    )
    let recoveryCalls = fixture.recoveryStore.calls

    XCTAssertEqual(decision, .interrupt(.audioInterruption))
    XCTAssertEqual(try fixture.store.readSnapshot().phase, .interrupted)
    XCTAssertEqual(recoveryCalls.map(\.sessionID), [sessionID])
    XCTAssertEqual(recoveryCalls.map(\.reason), [.audioInterruption])
    XCTAssertEqual(recoveryCalls.first?.audio, Data("partial-audio".utf8))
    XCTAssertEqual(fixture.audioSession.deactivationCount, 1)
    XCTAssertEqual(fixture.recorderFactory.stopCount, 1)
    let endedActivities = await fixture.activityManager.ended
    XCTAssertEqual(endedActivities, ["activity"])
  }

  func testBackgroundCaptureContinuesOnlyWithVisibleActivityOwnership() async throws {
    let visible = try CaptureFixture(liveActivityID: "activity")
    addTeardownBlock { try visible.remove() }
    try await visible.service.start(sessionID: UUID())

    let continued = await visible.service.handleLifecycleEvent(.enteredBackground)

    XCTAssertEqual(
      continued,
      .continueCapture(advisory: .backgroundRecording)
    )
    XCTAssertEqual(try visible.store.readSnapshot().phase, .recording)
    XCTAssertEqual(visible.recoveryStore.calls, [])
    _ = await visible.service.handleLifecycleEvent(.audioInterruptionBegan)

    let hidden = try CaptureFixture(liveActivityID: nil)
    addTeardownBlock { try hidden.remove() }
    try await hidden.service.start(sessionID: UUID())

    let interrupted = await hidden.service.handleLifecycleEvent(.enteredBackground)

    XCTAssertEqual(
      interrupted,
      .interrupt(.backgroundOwnershipUnavailable)
    )
    XCTAssertEqual(try hidden.store.readSnapshot().phase, .interrupted)
    XCTAssertEqual(
      hidden.recoveryStore.calls.map(\.reason),
      [.backgroundOwnershipUnavailable]
    )
  }

  func testBackgroundFinalizationExpirationPreservesPartialAudio() async throws {
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let transcriber = BlockingFinalizationTranscriber(
      entered: entered.continuation,
      release: release.stream
    )
    let backgroundTasks = RecordingBackgroundTaskManager()
    let fixture = try CaptureFixture(
      liveActivityID: "activity",
      transcriber: transcriber,
      backgroundTaskManager: backgroundTasks
    )
    addTeardownBlock { try fixture.remove() }
    let sessionID = UUID()
    try await fixture.service.start(sessionID: sessionID)
    let stopping = Task { try await fixture.service.stop(styleKind: .natural) }
    for await _ in entered.stream.prefix(1) {}

    await backgroundTasks.expire()
    release.continuation.finish()
    try await stopping.value

    XCTAssertEqual(try fixture.store.readSnapshot().phase, .interrupted)
    XCTAssertEqual(
      fixture.recoveryStore.calls.map(\.reason),
      [.backgroundExecutionExpired]
    )
    let activeBackgroundTaskCount = await backgroundTasks.activeCount
    XCTAssertEqual(activeBackgroundTaskCount, 0)
  }

  func testTranscribingPublishesHeartbeatsUntilFinalizationEnds() async throws {
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let fixture = try CaptureFixture(
      liveActivityID: "activity",
      transcriber: BlockingFinalizationTranscriber(
        entered: entered.continuation,
        release: release.stream
      ),
      heartbeatInterval: .milliseconds(10)
    )
    addTeardownBlock { try fixture.remove() }
    try await fixture.service.start(sessionID: UUID())
    let recordingSequence = try fixture.store.readSnapshot().sequence
    let stopping = Task { try await fixture.service.stop(styleKind: .natural) }
    for await _ in entered.stream.prefix(1) {}
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    var transcribing = try fixture.store.readSnapshot()
    while transcribing.sequence <= recordingSequence + 1,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(10))
      transcribing = try fixture.store.readSnapshot()
    }
    release.continuation.finish()
    _ = try? await stopping.value

    XCTAssertEqual(transcribing.phase, .transcribing)
    XCTAssertNotNil(transcribing.heartbeatAt)
    XCTAssertGreaterThan(transcribing.sequence, recordingSequence + 1)
  }

  func testInterruptionWhileLiveActivityStartsCannotReviveCapture() async throws {
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let activityManager = BlockingLiveActivityManager(
      startEntered: entered.continuation,
      startRelease: release.stream
    )
    let harness = try CaptureHarness(activityManager: activityManager)
    addTeardownBlock { try harness.remove() }
    let sessionID = UUID()
    let starting = Task { try await harness.service.start(sessionID: sessionID) }
    for await _ in entered.stream.prefix(1) {}

    let decision = await harness.service.handleLifecycleEvent(.audioInterruptionBegan)
    release.continuation.finish()

    do {
      try await starting.value
      XCTFail("An interrupted start must not publish recording state.")
    } catch {
      XCTAssertEqual(error as? VoiceInputCaptureError, .recordingFailed)
    }
    XCTAssertEqual(decision, .interrupt(.audioInterruption))
    XCTAssertEqual(try harness.store.readSnapshot().phase, .interrupted)
    let endedActivityIDs = await activityManager.endedIDs
    XCTAssertEqual(endedActivityIDs, ["activity"])
  }

  func testCaptureOwnershipClearsBeforeLiveActivityEndSuspends() async throws {
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let activityManager = BlockingLiveActivityManager(
      endEntered: entered.continuation,
      endRelease: release.stream
    )
    let harness = try CaptureHarness(activityManager: activityManager)
    addTeardownBlock { try harness.remove() }
    try await harness.service.start(sessionID: UUID())
    let interrupting = Task {
      await harness.service.interrupt(reason: .audioInterruption)
    }
    for await _ in entered.stream.prefix(1) {}

    let lateDecision = await harness.service.handleLifecycleEvent(
      .thermalStateChanged(.critical)
    )
    do {
      try await harness.service.start(sessionID: UUID())
      XCTFail("A new capture must wait for audio-session teardown.")
    } catch {
      XCTAssertEqual(error as? VoiceInputCaptureError, .alreadyRecording)
    }
    release.continuation.finish()
    await interrupting.value

    XCTAssertEqual(lateDecision, .ignore)
    XCTAssertEqual(harness.recoveryStore.calls.count, 1)
  }

  func testInterruptionAfterHistoryCommitDoesNotDowngradeReadyResult() async throws {
    let committed = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let history = CommitBlockingHistoryStore(
      committed: committed.continuation,
      release: release.stream
    )
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let store = LockedProbeStore(command: nil)
    let service = VoiceInputCaptureService(
      store: store,
      captureDirectoryURL: root,
      asrWorkflow: VoiceInputASRWorkflow(
        modelProvider: ImmediateASRModelProvider(),
        transcriber: ImmediateFinalizationTranscriber()
      ),
      sessionFinalizer: VoiceInputSessionFinalizer(history: history),
      recoveryStore: history,
      permissionRequester: { true },
      audioSession: RecordingAudioSession(),
      recorderFactory: RecordingAudioRecorderFactory(),
      activityManager: RecordingLiveActivityManager(startedID: "activity"),
      backgroundTaskManager: RecordingBackgroundTaskManager(),
      heartbeatInterval: .seconds(60)
    )
    try await service.start(sessionID: UUID())
    let stopping = Task { try await service.stop(styleKind: .natural) }
    for await _ in committed.stream.prefix(1) {}

    let decision = await service.handleLifecycleEvent(
      .thermalStateChanged(.critical)
    )
    release.continuation.finish()
    try await stopping.value

    XCTAssertEqual(decision, .ignore)
    XCTAssertEqual(try store.readSnapshot().phase, .ready)
    XCTAssertEqual(
      try store.readSnapshot().text,
      "Committed before interruption."
    )
  }
}

private struct CaptureHarness {
  let root: URL
  let store: LockedProbeStore
  let recoveryStore: RecordingRecoveryStore
  let service: VoiceInputCaptureService

  init(activityManager: any VoiceInputLiveActivityManaging) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    store = LockedProbeStore(command: nil)
    recoveryStore = RecordingRecoveryStore()
    service = VoiceInputCaptureService(
      store: store,
      captureDirectoryURL: root,
      asrWorkflow: VoiceInputASRWorkflow(
        modelProvider: ImmediateASRModelProvider(),
        transcriber: PrewarmingTranscriber()
      ),
      sessionFinalizer: VoiceInputSessionFinalizer(history: UnusedHistoryStore()),
      recoveryStore: recoveryStore,
      permissionRequester: { true },
      audioSession: RecordingAudioSession(),
      recorderFactory: RecordingAudioRecorderFactory(),
      activityManager: activityManager,
      backgroundTaskManager: RecordingBackgroundTaskManager(),
      heartbeatInterval: .seconds(60)
    )
  }

  func remove() throws {
    try FileManager.default.removeItem(at: root)
  }
}

private struct CaptureFixture {
  let root: URL
  let store: LockedProbeStore
  let recoveryStore: RecordingRecoveryStore
  let audioSession: RecordingAudioSession
  let recorderFactory: RecordingAudioRecorderFactory
  let activityManager: RecordingLiveActivityManager
  let service: VoiceInputCaptureService

  init(
    liveActivityID: String?,
    transcriber: any VoiceInputTranscribing = PrewarmingTranscriber(),
    backgroundTaskManager: any VoiceInputBackgroundTaskManaging =
      RecordingBackgroundTaskManager(),
    controlReloader: @escaping @Sendable () -> Void = {},
    heartbeatInterval: Duration = .seconds(60)
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    store = LockedProbeStore(command: nil)
    recoveryStore = RecordingRecoveryStore()
    audioSession = RecordingAudioSession()
    recorderFactory = RecordingAudioRecorderFactory()
    activityManager = RecordingLiveActivityManager(startedID: liveActivityID)
    let workflow = VoiceInputASRWorkflow(
      modelProvider: ImmediateASRModelProvider(),
      transcriber: transcriber
    )
    service = VoiceInputCaptureService(
      store: store,
      captureDirectoryURL: root,
      asrWorkflow: workflow,
      sessionFinalizer: VoiceInputSessionFinalizer(history: UnusedHistoryStore()),
      recoveryStore: recoveryStore,
      permissionRequester: { true },
      audioSession: audioSession,
      recorderFactory: recorderFactory,
      activityManager: activityManager,
      backgroundTaskManager: backgroundTaskManager,
      controlReloader: controlReloader,
      heartbeatInterval: heartbeatInterval
    )
  }

  func remove() throws {
    try FileManager.default.removeItem(at: root)
  }
}

private struct RecoveryCall: Equatable, Sendable {
  let sessionID: UUID
  let reason: VoiceInputCaptureInterruptionReason
  let audio: Data
}

private final class RecordingRecoveryStore: VoiceInputRecoveryStoring, Sendable {
  private let state = Mutex<[RecoveryCall]>([])

  var calls: [RecoveryCall] { state.withLock { $0 } }

  func preserveRecovery(
    sessionID: UUID,
    startedAt _: Date,
    endedAt _: Date,
    reason: VoiceInputCaptureInterruptionReason,
    sourceAudioURL: URL
  ) async throws -> VoiceInputRecoveryDisposition {
    let audio = try Data(contentsOf: sourceAudioURL)
    state.withLock {
      $0.append(RecoveryCall(sessionID: sessionID, reason: reason, audio: audio))
    }
    try FileManager.default.removeItem(at: sourceAudioURL)
    return .recovered
  }
}

private actor CommitBlockingHistoryStore: VoiceInputHistoryStoring,
  VoiceInputRecoveryStoring
{
  private let committed: AsyncStream<Void>.Continuation
  private let release: AsyncStream<Void>
  private var committedSession: VoiceInputHistorySession?

  init(
    committed: AsyncStream<Void>.Continuation,
    release: AsyncStream<Void>
  ) {
    self.committed = committed
    self.release = release
  }

  func save(
    sessionID: UUID,
    startedAt: Date,
    endedAt: Date,
    transcript: VoiceInputProcessedTranscript,
    sourceAudioURL _: URL
  ) async throws -> VoiceInputHistorySession {
    let session = VoiceInputHistorySession(
      id: sessionID,
      startedAt: startedAt,
      endedAt: endedAt,
      transcript: transcript,
      audioArtifact: nil,
      audioExpiredAt: endedAt,
      audioExpiredReason: .ageLimit
    )
    committedSession = session
    committed.yield()
    for await _ in release {}
    return session
  }

  func preserveRecovery(
    sessionID _: UUID,
    startedAt _: Date,
    endedAt _: Date,
    reason _: VoiceInputCaptureInterruptionReason,
    sourceAudioURL: URL
  ) throws -> VoiceInputRecoveryDisposition {
    guard let committedSession else {
      return .recovered
    }
    try FileManager.default.removeItem(at: sourceAudioURL)
    return .alreadyFinalized(formattedText: committedSession.formattedText)
  }
}

private final class RecordingAudioSession: VoiceInputAudioSessionControlling, Sendable {
  private let state = Mutex((activations: 0, deactivations: 0))

  var deactivationCount: Int { state.withLock { $0.deactivations } }

  func activateForRecording() throws {
    state.withLock { $0.activations += 1 }
  }

  func deactivateAfterRecording() throws {
    state.withLock { $0.deactivations += 1 }
  }
}

private final class RecordingAudioRecorderFactory: VoiceInputAudioRecorderCreating, Sendable {
  private let state = RecorderProbeState()

  var stopCount: Int { state.stopCount }

  func makeRecorder(at url: URL) throws -> any VoiceInputAudioRecording {
    state.add(url)
    return RecordingAudioRecorder(url: url, state: state)
  }
}

private final class RecorderProbeState: Sendable {
  private let state = Mutex((stopCount: 0, urls: [URL]()))

  var stopCount: Int { state.withLock { $0.stopCount } }

  func add(_ url: URL) {
    state.withLock { $0.urls.append(url) }
  }

  func stop() {
    state.withLock { $0.stopCount += 1 }
  }
}

private final class RecordingAudioRecorder: VoiceInputAudioRecording, Sendable {
  private let url: URL
  private let state: RecorderProbeState

  init(
    url: URL,
    state: RecorderProbeState
  ) {
    self.url = url
    self.state = state
  }

  func prepareToRecord() {}

  func record() -> Bool {
    do {
      try Data("partial-audio".utf8).write(to: url)
      return true
    } catch {
      return false
    }
  }

  func stop() {
    state.stop()
  }
}

private actor RecordingLiveActivityManager: VoiceInputLiveActivityManaging {
  private let startedID: String?
  private(set) var ended: [String] = []
  private(set) var orphanReconciliationCount = 0

  init(startedID: String?) {
    self.startedID = startedID
  }

  func start(sessionID _: UUID, at _: Date) -> String? {
    startedID
  }

  func update(id _: String?, phase _: VoiceInputSnapshot.Phase, at _: Date) {}

  func end(id: String?, phase _: VoiceInputSnapshot.Phase, at _: Date) {
    if let id {
      ended.append(id)
    }
  }

  func endOrphanedActivities(at _: Date) {
    orphanReconciliationCount += 1
  }
}

private actor BlockingLiveActivityManager: VoiceInputLiveActivityManaging {
  private let startEntered: AsyncStream<Void>.Continuation?
  private let startRelease: AsyncStream<Void>?
  private let endEntered: AsyncStream<Void>.Continuation?
  private let endRelease: AsyncStream<Void>?
  private(set) var endedIDs: [String] = []

  init(
    startEntered: AsyncStream<Void>.Continuation? = nil,
    startRelease: AsyncStream<Void>? = nil,
    endEntered: AsyncStream<Void>.Continuation? = nil,
    endRelease: AsyncStream<Void>? = nil
  ) {
    self.startEntered = startEntered
    self.startRelease = startRelease
    self.endEntered = endEntered
    self.endRelease = endRelease
  }

  func start(sessionID _: UUID, at _: Date) async -> String? {
    startEntered?.yield()
    if let startRelease {
      for await _ in startRelease {}
    }
    return "activity"
  }

  func update(id _: String?, phase _: VoiceInputSnapshot.Phase, at _: Date) {}

  func end(id: String?, phase _: VoiceInputSnapshot.Phase, at _: Date) async {
    guard let id else {
      return
    }
    endedIDs.append(id)
    endEntered?.yield()
    if let endRelease {
      for await _ in endRelease {}
    }
  }
}

private actor RecordingBackgroundTaskManager: VoiceInputBackgroundTaskManaging {
  private var expiration: (@Sendable () async -> Void)?
  private(set) var activeCount = 0

  func begin(
    name _: String,
    expiration: @escaping @Sendable () async -> Void
  ) -> VoiceInputBackgroundTaskToken? {
    self.expiration = expiration
    activeCount += 1
    return VoiceInputBackgroundTaskToken()
  }

  func end(_ token: VoiceInputBackgroundTaskToken?) {
    guard token != nil, activeCount > 0 else {
      return
    }
    activeCount -= 1
    expiration = nil
  }

  func expire() async {
    guard let expiration else {
      return
    }
    activeCount -= 1
    self.expiration = nil
    await expiration()
  }
}

private struct ImmediateASRModelProvider: VoiceInputASRModelProviding {
  func selectedASRModel() async throws -> VoiceInputInstalledModelPackage {
    makeInstalledASRPackage()
  }
}

private struct PrewarmingTranscriber: VoiceInputTranscribing {
  func prewarm(model _: VoiceInputInstalledModelPackage) async throws {}

  func transcribe(
    audioURL _: URL,
    model _: VoiceInputInstalledModelPackage
  ) async throws -> VoiceInputRawTranscript {
    throw CaptureServiceTestError.unused
  }
}

private struct ImmediateFinalizationTranscriber: VoiceInputTranscribing {
  func prewarm(model _: VoiceInputInstalledModelPackage) async throws {}

  func transcribe(
    audioURL _: URL,
    model _: VoiceInputInstalledModelPackage
  ) async throws -> VoiceInputRawTranscript {
    VoiceInputRawTranscript(
      text: "Committed before interruption.",
      segments: [],
      modelPackageID: "whisper",
      modelVersion: "1"
    )
  }
}

private actor BlockingFinalizationTranscriber: VoiceInputTranscribing {
  private let entered: AsyncStream<Void>.Continuation
  private let release: AsyncStream<Void>

  init(
    entered: AsyncStream<Void>.Continuation,
    release: AsyncStream<Void>
  ) {
    self.entered = entered
    self.release = release
  }

  func prewarm(model _: VoiceInputInstalledModelPackage) async throws {}

  func transcribe(
    audioURL _: URL,
    model _: VoiceInputInstalledModelPackage
  ) async throws -> VoiceInputRawTranscript {
    entered.yield()
    for await _ in release {}
    return VoiceInputRawTranscript(
      text: "Recovered before finalization.",
      segments: [],
      modelPackageID: "whisper",
      modelVersion: "1"
    )
  }
}

private enum CaptureServiceTestError: Error {
  case concurrentStart
  case released
  case unused
}

private actor BlockingASRModelProvider: VoiceInputASRModelProviding {
  private let entered: AsyncStream<Void>.Continuation
  private let release: AsyncStream<Void>
  private(set) var callCount = 0

  init(
    entered: AsyncStream<Void>.Continuation,
    release: AsyncStream<Void>
  ) {
    self.entered = entered
    self.release = release
  }

  func selectedASRModel() async throws -> VoiceInputInstalledModelPackage {
    callCount += 1
    guard callCount == 1 else {
      throw CaptureServiceTestError.concurrentStart
    }
    entered.yield()
    for await _ in release {}
    throw CaptureServiceTestError.released
  }
}

private struct UnusedTranscriber: VoiceInputTranscribing {
  func prewarm(model _: VoiceInputInstalledModelPackage) async throws {
    throw CaptureServiceTestError.unused
  }

  func transcribe(
    audioURL _: URL,
    model _: VoiceInputInstalledModelPackage
  ) async throws -> VoiceInputRawTranscript {
    throw CaptureServiceTestError.unused
  }
}

private struct UnusedHistoryStore: VoiceInputHistoryStoring {
  func save(
    sessionID _: UUID,
    startedAt _: Date,
    endedAt _: Date,
    transcript _: VoiceInputProcessedTranscript,
    sourceAudioURL _: URL
  ) async throws -> VoiceInputHistorySession {
    throw CaptureServiceTestError.unused
  }
}

private final class LockedProbeStore: VoiceInputStateStoring, Sendable {
  private struct State: Sendable {
    var snapshot = VoiceInputSnapshot.idle(sequence: 0)
    var command: VoiceInputCommand?
  }

  private let state: Mutex<State>

  init(
    command: VoiceInputCommand?,
    snapshot: VoiceInputSnapshot = .idle(sequence: 0)
  ) {
    state = Mutex(State(snapshot: snapshot, command: command))
  }

  func readSnapshot() throws -> VoiceInputSnapshot {
    state.withLock { $0.snapshot }
  }

  func writeSnapshot(_ snapshot: VoiceInputSnapshot) throws {
    state.withLock { $0.snapshot = snapshot }
  }

  func readCommand() throws -> VoiceInputCommand? {
    state.withLock { $0.command }
  }

  func writeCommand(_ command: VoiceInputCommand) throws {
    try state.withLock { state in
      guard state.command == nil else {
        throw VoiceInputStoreError.commandPending
      }
      state.command = command
    }
  }

  func consumeCommand() throws -> VoiceInputCommand? {
    state.withLock { state in
      defer { state.command = nil }
      return state.command
    }
  }
}
