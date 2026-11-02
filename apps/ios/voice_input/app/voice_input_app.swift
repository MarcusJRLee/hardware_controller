import AVFAudio
import HardwareControllerCore
import SwiftUI
import UIKit
import VoiceInputShared

@main
struct VoiceInputApp: App {
  @StateObject private var model: VoiceInputAppModel
  @StateObject private var modelLibrary: VoiceInputModelLibraryModel
  @StateObject private var history: VoiceInputHistoryModel
  @StateObject private var historyAudioPlayer: VoiceInputHistoryAudioPlayerModel
  @Environment(\.scenePhase) private var scenePhase

  @MainActor
  init() {
    let store = VoiceInputKeychainStore()
    #if DEBUG
      if VoiceInputUITestHooks.shouldReset(arguments: ProcessInfo.processInfo.arguments) {
        Self.resetForUITest(store: store)
      }
    #endif
    guard
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      _model = StateObject(
        wrappedValue: VoiceInputAppModel(store: store, service: nil)
      )
      _modelLibrary = StateObject(
        wrappedValue: VoiceInputModelLibraryModel(
          manager: UnavailableModelManager()
        )
      )
      _history = StateObject(
        wrappedValue: VoiceInputHistoryModel(
          history: nil,
          initializationError: "The local app container is unavailable."
        )
      )
      _historyAudioPlayer = StateObject(
        wrappedValue: VoiceInputHistoryAudioPlayerModel()
      )
      return
    }
    let modelRoot =
      applicationSupport
      .appendingPathComponent(
        "com.longdevity.hardwarecontroller.voiceinput",
        isDirectory: true
      )
      .appendingPathComponent("voice_models", isDirectory: true)
    let registry = VoiceInputASRModelRegistry(
      installer: VoiceInputModelPackageInstaller(rootURL: modelRoot),
      selectionURL: modelRoot.appendingPathComponent("active_asr.json")
    )
    let transcriber = VoiceInputLocalTranscriber()
    let asrWorkflow = VoiceInputASRWorkflow(
      modelProvider: registry,
      transcriber: transcriber,
      liveTranscriber: transcriber
    )
    let historyRoot =
      applicationSupport
      .appendingPathComponent(
        "com.longdevity.hardwarecontroller.voiceinput",
        isDirectory: true
      )
      .appendingPathComponent("history", isDirectory: true)
    let retentionPreferenceStore =
      VoiceInputHistoryRetentionPreferenceStore()
    let retentionSettings: VoiceHistoryRetentionSettings
    let retentionPreferences: VoiceInputHistoryRetentionPreferenceStore?
    let retentionInitializationError: String?
    do {
      retentionSettings = try retentionPreferenceStore.read()
      retentionPreferences = retentionPreferenceStore
      retentionInitializationError = nil
    } catch {
      retentionSettings = .iOSDefault
      retentionPreferences = nil
      retentionInitializationError =
        "History storage settings are read-only: \(error.localizedDescription) The saved value was preserved."
    }
    let historyRepository: VoiceInputHistoryRepository?
    let historyInitializationError: String?
    do {
      historyRepository = try VoiceInputHistoryRepository(
        rootURL: historyRoot,
        retentionSettings: retentionSettings
      )
      historyInitializationError = nil
    } catch {
      historyRepository = nil
      historyInitializationError = error.localizedDescription
    }
    var recorderFactory: any VoiceInputAudioRecorderCreating =
      VoiceInputSystemAudioRecorderFactory()
    var liveAudioTap: (any VoiceInputLiveAudioTapping)? = VoiceInputSystemLiveAudioTap()
    #if DEBUG
      if let fixtureURL = VoiceInputUITestHooks.audioFixtureURL(
        environment: ProcessInfo.processInfo.environment
      ) {
        recorderFactory = VoiceInputFixtureAudioRecorderFactory(fixtureURL: fixtureURL)
        liveAudioTap = nil
      }
    #endif
    let service = VoiceInputCaptureService(
      store: store,
      captureDirectoryURL: historyRoot.appendingPathComponent("audio", isDirectory: true),
      asrWorkflow: asrWorkflow,
      sessionFinalizer: historyRepository.map {
        VoiceInputSessionFinalizer(history: $0)
      },
      recoveryStore: historyRepository,
      recorderFactory: recorderFactory,
      liveAudioTap: liveAudioTap,
      controlReloader: VoiceInputSystemControlReloader.reload
    )
    _model = StateObject(
      wrappedValue: VoiceInputAppModel(store: store, service: service)
    )
    _modelLibrary = StateObject(
      wrappedValue: VoiceInputModelLibraryModel(
        manager: registry,
        asrWorkflow: asrWorkflow,
        starter: VoiceInputStarterModel()
      )
    )
    _history = StateObject(
      wrappedValue: VoiceInputHistoryModel(
        history: historyRepository,
        initializationError: historyInitializationError,
        retentionSettings: retentionSettings,
        retentionPreferences: retentionPreferences,
        retentionInitializationError: retentionInitializationError
      )
    )
    _historyAudioPlayer = StateObject(
      wrappedValue: VoiceInputHistoryAudioPlayerModel()
    )
  }

  var body: some Scene {
    WindowGroup {
      VoiceInputRootView(
        model: model,
        modelLibrary: modelLibrary,
        history: history,
        historyAudioPlayer: historyAudioPlayer
      )
      .onReceive(
        NotificationCenter.default.publisher(
          for: AVAudioSession.interruptionNotification
        )
      ) { notification in
        model.handleInterruption(notification)
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: AVAudioSession.routeChangeNotification
        )
      ) { notification in
        model.handleRouteChange(notification)
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: AVAudioSession.mediaServicesWereLostNotification
        )
      ) { _ in
        model.handleLifecycleEvent(.mediaServicesUnavailable)
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: AVAudioSession.mediaServicesWereResetNotification
        )
      ) { _ in
        model.handleLifecycleEvent(.mediaServicesUnavailable)
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: ProcessInfo.thermalStateDidChangeNotification
        )
      ) { _ in
        model.handleLifecycleEvent(
          VoiceInputLifecycleNotificationMapper().thermalState(
            ProcessInfo.processInfo.thermalState
          )
        )
      }
      .onReceive(
        NotificationCenter.default.publisher(
          for: .NSProcessInfoPowerStateDidChange
        )
      ) { _ in
        model.handleLifecycleEvent(
          .lowPowerModeChanged(
            isEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
          )
        )
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .background {
          model.handleLifecycleEvent(.enteredBackground)
        }
      }
      .onAppear { model.activate() }
      .onDisappear {
        model.deactivate()
        historyAudioPlayer.stop()
      }
    }
  }

  #if DEBUG
    /// UI tests start from a fresh install without reinstalling the app.
    @MainActor
    private static func resetForUITest(store: VoiceInputKeychainStore) {
      do {
        try store.removeAll()
        if let applicationSupport = FileManager.default.urls(
          for: .applicationSupportDirectory,
          in: .userDomainMask
        ).first {
          let root = applicationSupport.appendingPathComponent(
            "com.longdevity.hardwarecontroller.voiceinput",
            isDirectory: true
          )
          if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
          }
        }
      } catch {
        fatalError("UI-test reset failed: \(error)")
      }
    }
  #endif
}
