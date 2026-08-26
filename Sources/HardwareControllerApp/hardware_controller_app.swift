import AppKit
import HardwareControllerCore
import HardwareControllerMac
import SwiftUI

/// Defines the lifecycle commands forwarded from workspace notifications.
@MainActor
protocol ApplicationLifecycleHandling: AnyObject {
  /// Ends active work before system sleep.
  func prepareForSleep() async

  /// Restarts input after system wake.
  func resumeAfterWake()
}

extension AppModel: ApplicationLifecycleHandling {}

/// Owns idempotent workspace notification registration.
@MainActor
final class WorkspaceLifecycleCoordinator: NSObject {
  private let application: any ApplicationLifecycleHandling
  private let notificationCenter: NotificationCenter
  private var isStarted = false

  /// Creates a coordinator around one lifecycle owner and notification source.
  init(
    application: any ApplicationLifecycleHandling,
    notificationCenter: NotificationCenter =
      NSWorkspace.shared.notificationCenter
  ) {
    self.application = application
    self.notificationCenter = notificationCenter
  }

  /// Registers sleep and wake observation exactly once.
  func start() {
    guard !isStarted else {
      return
    }
    isStarted = true
    notificationCenter.addObserver(
      self,
      selector: #selector(workspaceWillSleep),
      name: NSWorkspace.willSleepNotification,
      object: nil
    )
    notificationCenter.addObserver(
      self,
      selector: #selector(workspaceDidWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
  }

  /// Removes every workspace observer exactly once.
  func stop() {
    guard isStarted else {
      return
    }
    notificationCenter.removeObserver(self)
    isStarted = false
  }

  /// Ends active Actions before macOS suspends hardware and audio.
  @objc
  private func workspaceWillSleep() {
    Task { [application] in
      await application.prepareForSleep()
    }
  }

  /// Restarts hardware discovery after macOS restores the workspace.
  @objc
  private func workspaceDidWake() {
    application.resumeAfterWake()
  }
}

@main
struct HardwareControllerApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self)
  private var appDelegate

  var body: some Scene {
    MenuBarExtra {
      MenuBarContent(
        model: appDelegate.model,
        openController: {
          appDelegate.showApplicationWindow(.controller)
        },
        openHistory: {
          appDelegate.showApplicationWindow(.history)
        },
        manageProfiles: {
          appDelegate.showApplicationWindow(.profiles)
        },
        openSettings: {
          appDelegate.showApplicationWindow(.general)
        }
      )
    } label: {
      Image(
        nsImage: ControllerMenuBarIcon.image(
          active:
            appDelegate.model.isAnyActionActive
            || appDelegate.model.isTranscriptionActive
        )
      )
      .accessibilityLabel("Hardware Controller")
    }
    .menuBarExtraStyle(.menu)
    .commands {
      SidebarCommands()

      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          appDelegate.showApplicationWindow(.general)
        }
        .keyboardShortcut(",")
      }
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model: AppModel
  let navigation: ApplicationNavigationModel
  let preferencesModel: ApplicationPreferencesModel
  let historyModel: VoiceHistoryModel

  private var isLoginItemLaunch = false
  private var applicationWindowController: NSWindowController?
  private let appearanceAdapter: AppKitApplicationAppearanceAdapter
  private let historyReformatter: LocalAIVoiceHistoryReformatter
  private let terminationCoordinator =
    AppTerminationCoordinator()
  private lazy var workspaceLifecycle =
    WorkspaceLifecycleCoordinator(application: model)

  /// Creates one shared application, navigation, and preference state graph.
  override init() {
    let arguments = ProcessInfo.processInfo.arguments
    let appearanceAdapter = AppKitApplicationAppearanceAdapter()
    let preferencesModel = ApplicationPreferencesModel(
      arguments: arguments,
      isDemoMode: arguments.contains("--demo"),
      appearanceApplier: appearanceAdapter
    )
    let model = AppModel(
      arguments: arguments,
      preferredMicrophoneUID:
        preferencesModel.preferredMicrophone?.id,
      localAISettings: preferencesModel.localAISettings,
      voiceTriggerSettings: preferencesModel.voiceTriggerSettings
    )
    let historyPresentation = VoiceHistoryPresentation(
      arguments: arguments,
      localAISettings: preferencesModel.localAISettings
    )
    self.model = model
    navigation = ApplicationNavigationModel(arguments: arguments)
    self.appearanceAdapter = appearanceAdapter
    self.preferencesModel = preferencesModel
    historyModel = historyPresentation.model
    historyReformatter = historyPresentation.reformatter
    super.init()
    preferencesModel.setMicrophoneSelectionHandler {
      [weak model] uniqueID in
      model?.setPreferredMicrophoneUID(uniqueID)
    }
    preferencesModel.setLocalAISettingsHandler {
      [weak model, historyReformatter] settings in
      model?.setLocalAISettings(settings)
      Task {
        await historyReformatter.setSettings(settings)
      }
    }
    preferencesModel.setVoiceTriggerSettingsHandler {
      [weak model] settings in
      model?.setVoiceTriggerSettings(settings)
    }
  }

  func applicationWillFinishLaunching(
    _ notification: Notification
  ) {
    isLoginItemLaunch =
      AppLaunchPresentation.isCurrentLaunchFromLoginItem
  }

  func applicationDidFinishLaunching(
    _ notification: Notification
  ) {
    workspaceLifecycle.start()
    NSApp.setActivationPolicy(
      AppLaunchPresentation.activationPolicy
    )
    model.start()
    if AppLaunchPresentation.shouldPresentApplicationWindow(
      arguments: ProcessInfo.processInfo.arguments,
      isLoginItemLaunch: isLoginItemLaunch
    ) {
      DispatchQueue.main.async { [weak self] in
        guard let self else {
          return
        }
        showApplicationWindow(navigation.selectedDestination)
      }
    }
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    showApplicationWindow(.controller)
    return true
  }

  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    historyModel.stopPlayback()
    return terminationCoordinator.requestTermination(
      shutdown: { [model, historyReformatter] in
        async let applicationShutdown: Void = model.stop()
        async let historyShutdown: Void = historyReformatter.shutdown()
        _ = await (applicationShutdown, historyShutdown)
      },
      reply: {
        sender.reply(
          toApplicationShouldTerminate: true
        )
      }
    )
  }

  /// Raises the single application window at one requested destination.
  func showApplicationWindow(
    _ destination: AppDestination = .controller
  ) {
    navigation.select(destination)
    let windowController: NSWindowController

    if let applicationWindowController {
      windowController = applicationWindowController
    } else {
      let hostingController = NSHostingController(
        rootView: applicationRootView()
      )
      let window = NSWindow(
        contentViewController: hostingController
      )
      configureApplicationWindow(window)

      windowController = NSWindowController(window: window)
      applicationWindowController = windowController
    }

    windowController.showWindow(nil)
    windowController.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Builds the shared shell with deterministic demo accessibility overrides.
  private func applicationRootView() -> AnyView {
    var root = AnyView(
      ApplicationShellView(
        model: model,
        navigation: navigation,
        preferencesModel: preferencesModel,
        historyModel: historyModel
      )
    )
    guard model.isDemoMode else {
      return root
    }

    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains("--ui-increased-contrast") {
      root = AnyView(
        root.environment(\.demoIncreasedContrast, true)
      )
    }
    if arguments.contains("--ui-reduce-motion") {
      root = AnyView(root.transaction { $0.disablesAnimations = true })
    }
    if arguments.contains("--ui-large-text") {
      root = AnyView(
        root.environment(\.dynamicTypeSize, .accessibility1)
      )
    }
    return root
  }
}

/// Applies stable native framing to the application window.
@MainActor
func configureApplicationWindow(_ window: NSWindow) {
  window.title = "Hardware Controller"
  window.styleMask = [
    .titled,
    .closable,
    .miniaturizable,
    .resizable,
  ]
  window.titleVisibility = .hidden
  window.titlebarAppearsTransparent = false
  window.titlebarSeparatorStyle = .line
  window.contentMinSize = NSSize(width: 1_000, height: 660)
  window.setContentSize(
    NSSize(width: 1_160, height: 800)
  )
  window.center()
  window.isReleasedWhenClosed = false
  window.animationBehavior = .documentWindow
}

private struct MenuBarContent: View {
  let model: AppModel
  let openController: () -> Void
  let openHistory: () -> Void
  let manageProfiles: () -> Void
  let openSettings: () -> Void

  var body: some View {
    Group {
      Label(
        statusTitle,
        systemImage: model.requiresInstallation
          ? "externaldrive.badge.exclamationmark"
          : model.hardwareInputFailure != nil
            ? "exclamationmark.triangle.fill"
            : model.isConnected
              && model.hasBlockedConfiguredAction
              ? "hand.raised.fill"
              : model.isConnected
                ? "checkmark.circle.fill"
                : "cable.connector.slash"
      )

      if model.isTranscriptionActive {
        Label(
          menuTranscriptionTitle,
          systemImage: "waveform.circle.fill"
        )
      }

      Divider()

      Picker(
        "Active Profile",
        selection: Binding(
          get: { model.envelope.activeProfileID },
          set: { model.activateProfile(id: $0) }
        )
      ) {
        ForEach(model.profiles) { profile in
          Text(profile.name).tag(profile.id)
        }
      }

      Divider()

      Button("Open Controller…") {
        openController()
      }

      Button("Open Voice History…") {
        openHistory()
      }

      Button("Manage Profiles…") {
        manageProfiles()
      }

      Button("Settings…") {
        openSettings()
      }

      Toggle(
        "Launch at Login",
        isOn: Binding(
          get: { model.launchAtLogin },
          set: { model.setLaunchAtLogin($0) }
        )
      )
      .disabled(!model.canManageLaunchAtLogin)

      Divider()

      Button("Quit Hardware Controller") {
        NSApp.terminate(nil)
      }
      .keyboardShortcut("q")
    }
  }

  private var statusTitle: String {
    if model.requiresInstallation {
      return "Install required"
    }
    if model.hardwareInputFailure != nil {
      return "Controller unavailable"
    }
    if model.isConnected && model.hasBlockedConfiguredAction {
      return "Action blocked"
    }
    if model.connectedDevices.count == 1,
      let device = model.connectedDevices.first
    {
      return "\(device.name) connected"
    }
    if model.isConnected {
      return "\(model.connectedDevices.count) controllers connected"
    }
    return "Waiting for controller"
  }

  private var menuTranscriptionTitle: String {
    switch model.transcriptionSnapshot.phase {
    case .preparing:
      "Preparing local transcription"
    case .listening:
      "Listening locally"
    case .finalizing:
      "Finalizing transcription"
    case .canceling:
      "Canceling transcription"
    case .idle, .completed, .failed:
      "Local transcription"
    }
  }
}
