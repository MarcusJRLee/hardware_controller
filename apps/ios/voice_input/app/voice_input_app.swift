import AVFAudio
import HardwareControllerVoiceCore
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
    let asrWorkflow = VoiceInputASRWorkflow(
      modelProvider: registry,
      transcriber: VoiceInputWhisperTranscriber()
    )
    let historyRoot =
      applicationSupport
      .appendingPathComponent(
        "com.longdevity.hardwarecontroller.voiceinput",
        isDirectory: true
      )
      .appendingPathComponent("history", isDirectory: true)
    let historyRepository: VoiceInputHistoryRepository?
    let historyInitializationError: String?
    do {
      historyRepository = try VoiceInputHistoryRepository(
        rootURL: historyRoot,
        retentionSettings: .iOSDefault
      )
      historyInitializationError = nil
    } catch {
      historyRepository = nil
      historyInitializationError = error.localizedDescription
    }
    let service = VoiceInputCaptureService(
      store: store,
      captureDirectoryURL: historyRoot.appendingPathComponent("audio", isDirectory: true),
      asrWorkflow: asrWorkflow,
      sessionFinalizer: historyRepository.map {
        VoiceInputSessionFinalizer(history: $0)
      },
      recoveryStore: historyRepository
    )
    _model = StateObject(
      wrappedValue: VoiceInputAppModel(store: store, service: service)
    )
    _modelLibrary = StateObject(
      wrappedValue: VoiceInputModelLibraryModel(
        manager: registry,
        asrWorkflow: asrWorkflow
      )
    )
    _history = StateObject(
      wrappedValue: VoiceInputHistoryModel(
        history: historyRepository,
        initializationError: historyInitializationError
      )
    )
    _historyAudioPlayer = StateObject(
      wrappedValue: VoiceInputHistoryAudioPlayerModel()
    )
  }

  var body: some Scene {
    WindowGroup {
      VoiceInputView(
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
}

private struct VoiceInputView: View {
  @ObservedObject var model: VoiceInputAppModel
  @ObservedObject var modelLibrary: VoiceInputModelLibraryModel
  @ObservedObject var history: VoiceInputHistoryModel
  @ObservedObject var historyAudioPlayer: VoiceInputHistoryAudioPlayerModel
  @Environment(\.openURL) private var openURL

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Voice anywhere. Private by default.")
              .font(.largeTitle.bold())
            Text(
              "Capture long thoughts without sending audio, transcripts, or context off this iPhone."
            )
            .foregroundStyle(.secondary)
          }

          VoiceInputOnboardingView(
            step: model.onboardingStep,
            microphoneAuthorization: model.microphoneAuthorization,
            keyboardHandoffObserved: model.keyboardHandoffObserved,
            errorMessage: model.onboardingErrorMessage,
            requestMicrophone: model.requestMicrophone,
            openSettings: openSettings
          )

          VoiceInputModelLibraryView(model: modelLibrary)

          captureSection

          VoiceInputHistoryView(
            model: history,
            audioPlayer: historyAudioPlayer
          )

          if let errorMessage = model.errorMessage ?? model.snapshotErrorMessage {
            Text(errorMessage)
              .foregroundStyle(.red)
              .accessibilityIdentifier("capture_error")
          }
        }
        .padding(24)
      }
      .navigationTitle("Voice Input")
      .task {
        await modelLibrary.refresh()
        await history.refresh()
      }
      .task(id: model.snapshot.sequence) {
        if model.snapshot.phase == .ready {
          await history.refresh()
        }
      }
    }
  }

  private var captureSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Capture").font(.title2.bold())
        Spacer()
        Picker(
          "Style",
          selection: Binding(
            get: { model.selectedStyleKind },
            set: { model.selectStyle($0) }
          )
        ) {
          ForEach(VoiceInputStyleKind.allCases, id: \.self) { styleKind in
            Text(styleKind.displayName).tag(styleKind)
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("capture_style")
      }
      statusCard

      if let lifecycleMessage = model.lifecycleMessage {
        Label(lifecycleMessage, systemImage: "info.circle")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("capture_lifecycle")
      }

      Button {
        if model.isRecording {
          model.stop()
        } else {
          model.start()
        }
      } label: {
        Label(
          model.isRecording ? "Stop local capture" : "Start local capture",
          systemImage: model.isRecording ? "stop.fill" : "mic.fill"
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!model.canCapture)
      .accessibilityIdentifier(
        model.isRecording ? "stop_capture" : "start_capture"
      )
    }
  }

  private func openSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else {
      return
    }
    openURL(url)
  }

  private var statusCard: some View {
    HStack(spacing: 12) {
      Image(systemName: statusSymbol)
        .font(.title2)
      VStack(alignment: .leading, spacing: 2) {
        Text(statusTitle).font(.headline)
        Text(statusDetail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Capture status")
    .accessibilityValue(statusTitle)
    .accessibilityIdentifier("capture_status")
  }

  private var statusSymbol: String {
    switch model.snapshot.phase {
    case .idle: "circle"
    case .recording: "waveform"
    case .transcribing: "ellipsis"
    case .ready: "checkmark.circle.fill"
    case .interrupted: "exclamationmark.triangle"
    case .failed: "xmark.circle"
    }
  }

  private var statusTitle: String {
    model.snapshot.phase.rawValue.capitalized
  }

  private var statusDetail: String {
    switch model.snapshot.phase {
    case .idle: "Ready for local capture."
    case .recording: "Recording locally. Switch to the keyboard and tap its mic to stop."
    case .transcribing: "Finalizing locally."
    case .ready: "Result ready for one-time keyboard insertion."
    case .interrupted: "Capture stopped after an audio interruption. Start again manually."
    case .failed: "Capture stopped with an explicit failure."
    }
  }
}
