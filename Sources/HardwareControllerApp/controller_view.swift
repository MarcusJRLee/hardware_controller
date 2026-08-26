import AppKit
import HardwareControllerCore
import HardwareControllerMac
import SwiftUI

struct ControllerView: View {
  @Environment(\.colorScheme) private var colorScheme
  let model: AppModel
  let manageProfiles: () -> Void

  var body: some View {
    ZStack {
      background

      ScrollView {
        VStack(spacing: 18) {
          header

          if let notice = model.recoveryNotice ?? model.lastError {
            NoticeBanner(
              message: notice,
              dismiss: model.clearNotice
            )
          }

          if let message = model.hardwareInputMessage {
            HardwareInputCard(
              message: message,
              retry: model.retryHardwareInput
            )
          }

          if model.requiresInstallation {
            InstallationCard(model: model)
          }

          if !model.accessibilityTrusted && !model.requiresInstallation {
            AccessibilityCard(model: model)
          }

          if model.hasDictationAction
            && model.microphonePermission != .authorized
            && !model.requiresInstallation
          {
            TranscriptionPermissionCard(
              title: "Allow microphone access",
              detail:
                "Hardware Controller needs the microphone only while a Local Dictation control is active.",
              systemImage: "mic.fill",
              status: model.microphonePermission,
              request: model.requestMicrophone,
              openSettings: model.openMicrophoneSettings
            )
          }

          if model.hasDictationAction
            && LegacySpeechPermission.isRequired
            && model.speechRecognitionPermission != .authorized
            && !model.requiresInstallation
          {
            TranscriptionPermissionCard(
              title: "Allow speech recognition",
              detail:
                "macOS 15–25 requires Speech Recognition access for Apple's on-device recognizer.",
              systemImage: "waveform",
              status: model.speechRecognitionPermission,
              request: model.requestSpeechRecognition,
              openSettings:
                model.openSpeechRecognitionSettings
            )
          }

          if model.actionDispatchFailed {
            ActionDispatchCard()
          }

          if model.connectedDevices.isEmpty {
            ControlStageView(
              model: model,
              device: nil,
              descriptor: model.defaultDeviceDescriptor
            )
          } else {
            ForEach(model.connectedDevices, id: \.id) { device in
              ControlStageView(
                model: model,
                device: device,
                descriptor: device.model
              )
            }
          }

          if model.hasLocalDictationAction
            || model.transcriptionSnapshot.phase != .idle
          {
            TranscriptionStatusView(model: model)
          }

          if model.hasLocalAIAction
            || model.localAIDictationSnapshot.phase != .idle
          {
            LocalAITranscriptionStatusView(model: model)
          }

          if model.hasLegacyDictationShortcut {
            LegacyShortcutCard()
          }

          ForEach(
            model.supportedDeviceDescriptors,
            id: \.modelID
          ) { descriptor in
            if let configuration = model.activeProfile.configuration(
              matching: DeviceMatchRule(modelID: descriptor.modelID)
            ) {
              DeviceBindingEditor(
                model: model,
                descriptor: descriptor,
                profileID: model.activeProfile.id,
                configurationID: configuration.id
              )
            } else {
              UnconfiguredDeviceCard(
                deviceName: descriptor.name,
                manageProfiles: manageProfiles
              )
            }
          }

          DictationSetupView(model: model)

          footer
        }
        .padding(26)
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.hidden)
    }
    .frame(minWidth: 820, minHeight: 660)
    .tint(StudioDesign.accent)
  }

  private var background: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)

      RadialGradient(
        colors: [
          StudioDesign.accent.opacity(
            colorScheme == .dark ? 0.10 : 0.07
          ),
          .clear,
        ],
        center: .topTrailing,
        startRadius: 30,
        endRadius: 520
      )

      RadialGradient(
        colors: [
          StudioDesign.activeBlue.opacity(
            colorScheme == .dark ? 0.07 : 0.04
          ),
          .clear,
        ],
        center: .bottomLeading,
        startRadius: 10,
        endRadius: 480
      )
    }
    .ignoresSafeArea()
  }

  private var header: some View {
    HStack(spacing: 14) {
      AppMark()

      VStack(alignment: .leading, spacing: 2) {
        Text("HARDWARE CONTROLLER")
          .font(
            .system(
              .caption2,
              design: .rounded,
              weight: .bold
            )
          )
          .tracking(1.8)
          .foregroundStyle(.secondary)

        Text("Your controls, exactly as you want them.")
          .font(
            .system(
              .title3,
              design: .default,
              weight: .semibold
            )
          )
      }

      Spacer()

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
      .pickerStyle(.menu)
      .fixedSize()

      Button("Manage") {
        manageProfiles()
      }
      .buttonStyle(.borderless)
      .help("Manage Profiles")

      if model.isDemoMode {
        StatusPill(
          title: "Demo input",
          systemImage: "sparkles",
          color: StudioDesign.activeBlue
        )
      } else if model.requiresInstallation {
        StatusPill(
          title: "Install required",
          systemImage: "externaldrive.badge.exclamationmark",
          color: StudioDesign.warning
        )
      } else if model.hardwareInputFailure != nil {
        StatusPill(
          title: "Controller unavailable",
          systemImage: "exclamationmark.triangle.fill",
          color: StudioDesign.warning
        )
      } else if model.actionDispatchFailed {
        StatusPill(
          title: "Action failed",
          systemImage: "exclamationmark.triangle.fill",
          color: StudioDesign.warning
        )
      } else if model.isConnected
        && model.hasBlockedConfiguredAction
      {
        StatusPill(
          title: "Action blocked",
          systemImage: "hand.raised.fill",
          color: StudioDesign.warning
        )
      } else if model.isConnected {
        StatusPill(
          title: "Ready",
          systemImage: "checkmark.circle.fill",
          color: StudioDesign.accent
        )
      } else {
        StatusPill(
          title: "Controller disconnected",
          systemImage: "cable.connector.slash",
          color: .secondary
        )
      }
    }
  }

  private var footer: some View {
    HStack {
      Label("Local only", systemImage: "lock.fill")
      Text("•")
      Text("No accounts")
      Text("•")
      Text("No cloud inference")

      Spacer()

      if let latency = model.latencyText {
        Label(
          "\(latency) input dispatch",
          systemImage: "bolt.fill"
        )
      }
    }
    .font(
      .system(
        .caption2,
        design: .default,
        weight: .medium
      )
    )
    .foregroundStyle(.tertiary)
    .padding(.horizontal, 4)
  }
}

/// Explains the safe inert fallback for an unconfigured active Device.
private struct UnconfiguredDeviceCard: View {
  let deviceName: String
  let manageProfiles: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "slider.horizontal.3")
        .font(.title2)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 3) {
        Text("\(deviceName) is not configured")
          .font(.headline)
        Text(
          "Its controls remain inactive until this Profile has a Device setup."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      Button("Add Device Setup") {
        manageProfiles()
      }
    }
    .padding(16)
    .studioCard()
  }
}

private struct ActionDispatchCard: View {
  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "keyboard.badge.exclamationmark")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(StudioDesign.warning)
        .frame(width: 42, height: 42)
        .background(
          StudioDesign.warning.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 11)
        )

      VStack(alignment: .leading, spacing: 3) {
        Text("Action could not start")
          .font(
            .system(
              .subheadline,
              design: .default,
              weight: .semibold
            )
          )
        Text(
          "The physical press was received, but the configured action could not be dispatched. Check the permission cards and try again."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)
    }
    .padding(15)
    .background(
      StudioDesign.warning.opacity(0.07),
      in: RoundedRectangle(
        cornerRadius: StudioDesign.compactCornerRadius,
        style: .continuous
      )
    )
    .overlay {
      RoundedRectangle(
        cornerRadius: StudioDesign.compactCornerRadius,
        style: .continuous
      )
      .strokeBorder(StudioDesign.warning.opacity(0.20))
    }
  }
}

private struct InstallationCard: View {
  let model: AppModel

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "arrow.down.app.fill")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(StudioDesign.warning)
        .frame(width: 42, height: 42)
        .background(
          StudioDesign.warning.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 11)
        )

      VStack(alignment: .leading, spacing: 3) {
        Text("Install before using")
          .font(
            .system(
              .subheadline,
              design: .default,
              weight: .semibold
            )
          )
        Text(
          "This copy is running from a disk image. Drag Hardware Controller to Applications, quit this copy, eject the disk image, and reopen the installed app."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      Button("Show Installer", action: model.revealInstaller)
        .buttonStyle(.borderedProminent)
    }
    .padding(15)
    .background(
      StudioDesign.warning.opacity(0.07),
      in: RoundedRectangle(
        cornerRadius: StudioDesign.compactCornerRadius,
        style: .continuous
      )
    )
    .overlay {
      RoundedRectangle(
        cornerRadius: StudioDesign.compactCornerRadius,
        style: .continuous
      )
      .strokeBorder(StudioDesign.warning.opacity(0.20))
    }
  }
}

private struct AppMark: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              StudioDesign.accent,
              StudioDesign.activeBlue,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )

      HStack(alignment: .bottom, spacing: 3) {
        markBar(height: 14)
        markBar(height: 22)
        markBar(height: 14)
      }
    }
    .frame(width: 46, height: 46)
    .shadow(color: StudioDesign.accent.opacity(0.24), radius: 12, y: 5)
    .accessibilityHidden(true)
  }

  private func markBar(height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
      .fill(.white.opacity(0.94))
      .frame(width: 5, height: height)
  }
}

struct NoticeBanner: View {
  let message: String
  let dismiss: (() -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(StudioDesign.warning)
      Text(message)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let dismiss {
        Button("Dismiss", action: dismiss)
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
      }
    }
    .padding(13)
    .background(
      StudioDesign.warning.opacity(0.10),
      in: RoundedRectangle(
        cornerRadius: StudioDesign.compactCornerRadius,
        style: .continuous
      )
    )
  }
}

private struct HardwareInputCard: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "cable.connector.slash")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(StudioDesign.warning)
        .frame(width: 42, height: 42)
        .background(
          StudioDesign.warning.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 11)
        )

      VStack(alignment: .leading, spacing: 3) {
        Text("Controller unavailable")
          .font(
            .system(
              .subheadline,
              design: .default,
              weight: .semibold
            )
          )
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      Button("Retry", action: retry)
        .buttonStyle(.borderedProminent)
    }
    .padding(15)
    .background(
      StudioDesign.warning.opacity(0.07),
      in: RoundedRectangle(
        cornerRadius: StudioDesign.compactCornerRadius,
        style: .continuous
      )
    )
    .overlay {
      RoundedRectangle(
        cornerRadius: StudioDesign.compactCornerRadius,
        style: .continuous
      )
      .strokeBorder(StudioDesign.warning.opacity(0.20))
    }
  }
}

private struct AccessibilityCard: View {
  let model: AppModel

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "hand.raised.fill")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(StudioDesign.warning)
        .frame(width: 42, height: 42)
        .background(
          StudioDesign.warning.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 11)
        )

      VStack(alignment: .leading, spacing: 3) {
        Text("Allow focused-app control")
          .font(
            .system(
              .subheadline,
              design: .default,
              weight: .semibold
            )
          )
        Text(
          "Accessibility lets Hardware Controller insert local text and send your chosen shortcuts. Only the optional Local AI nearby-text setting reads a bounded window from the selected nonsecure field. The app never monitors your keystrokes."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      Button("Open Settings") {
        model.requestAccessibility()
        model.openAccessibilitySettings()
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(15)
    .background(
      StudioDesign.warning.opacity(0.07),
      in: RoundedRectangle(
        cornerRadius: StudioDesign.compactCornerRadius,
        style: .continuous
      )
    )
    .overlay {
      RoundedRectangle(
        cornerRadius: StudioDesign.compactCornerRadius,
        style: .continuous
      )
      .strokeBorder(StudioDesign.warning.opacity(0.20))
    }
  }
}

private struct TranscriptionPermissionCard: View {
  let title: String
  let detail: String
  let systemImage: String
  let status: PermissionStatus
  let request: () -> Void
  let openSettings: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: systemImage)
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(StudioDesign.warning)
        .frame(width: 42, height: 42)
        .background(
          StudioDesign.warning.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 11)
        )

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(
            .system(
              .subheadline,
              design: .default,
              weight: .semibold
            )
          )
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      Button(
        status == .notDetermined
          ? "Allow"
          : "Open Settings"
      ) {
        if status == .notDetermined {
          request()
        } else {
          openSettings()
        }
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(15)
    .background(
      StudioDesign.warning.opacity(0.07),
      in: RoundedRectangle(
        cornerRadius: StudioDesign.compactCornerRadius,
        style: .continuous
      )
    )
    .overlay {
      RoundedRectangle(
        cornerRadius: StudioDesign.compactCornerRadius,
        style: .continuous
      )
      .strokeBorder(StudioDesign.warning.opacity(0.20))
    }
  }
}

private struct LegacyShortcutCard: View {
  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: 21, weight: .semibold))
        .foregroundStyle(StudioDesign.warning)
        .frame(width: 42, height: 42)
        .background(
          StudioDesign.warning.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 11)
        )

      VStack(alignment: .leading, spacing: 3) {
        Text("Switch this control to Local Dictation")
          .font(.subheadline.weight(.semibold))
        Text(
          "A Control–Option keyboard shortcut is still selected. That asks macOS to handle the key command; it does not use Hardware Controller's local transcription. Change the control's Action below to Local Dictation."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
    }
    .padding(15)
    .background(
      StudioDesign.warning.opacity(0.07),
      in: RoundedRectangle(
        cornerRadius: StudioDesign.compactCornerRadius,
        style: .continuous
      )
    )
    .overlay {
      RoundedRectangle(
        cornerRadius: StudioDesign.compactCornerRadius,
        style: .continuous
      )
      .strokeBorder(StudioDesign.warning.opacity(0.20))
    }
  }
}

private struct TranscriptionStatusView: View {
  let model: AppModel

  private var snapshot: TranscriptionSnapshot {
    model.transcriptionSnapshot
  }

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: snapshot.phase.systemImage)
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(snapshot.phase.color)
        .frame(width: 42, height: 42)
        .background(
          snapshot.phase.color.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 11)
        )

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(snapshot.phase.displayTitle)
            .font(.subheadline.weight(.semibold))
          if let target = snapshot.targetApplicationName,
            snapshot.phase != .idle
          {
            Text("→ \(target)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Text(statusDetail)
          .font(.caption)
          .foregroundStyle(
            snapshot.phase == .failed
              ? StudioDesign.warning
              : .secondary
          )
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      if snapshot.hasRecoverableTranscript {
        Button("Copy Text") {
          model.copyRecoverableTranscript()
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(15)
    .studioCard(highlighted: snapshot.phase.isActive)
  }

  private var statusDetail: String {
    if let failure = snapshot.failure {
      return snapshot.hasRecoverableTranscript
        ? "\(failure.recoveryMessage) Recognized text remains available to copy."
        : failure.recoveryMessage
    }
    if !snapshot.volatileText.isEmpty {
      return snapshot.volatileText
    }
    if !snapshot.finalText.isEmpty {
      return snapshot.finalText
    }
    switch snapshot.phase {
    case .idle:
      return
        "Click a text field in another app, then hold the assigned control while you speak."
    case .preparing:
      return "Preparing the on-device speech model…"
    case .listening:
      return "Listening locally. Release the control when finished."
    case .finalizing:
      return "Finishing the transcript and inserting final text…"
    case .canceling:
      return "Canceling this transcription…"
    case .completed:
      return "The local transcript was inserted successfully."
    case .failed:
      return "Local transcription could not finish."
    }
  }
}

private struct LocalAITranscriptionStatusView: View {
  let model: AppModel

  private var snapshot: LocalAIDictationSnapshot {
    model.localAIDictationSnapshot
  }

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: snapshot.phase.systemImage)
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(snapshot.phase.color)
        .frame(width: 42, height: 42)
        .background(
          snapshot.phase.color.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 11)
        )

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(snapshot.phase.displayTitle)
            .font(.subheadline.weight(.semibold))
          if let target = snapshot.targetApplicationName,
            snapshot.phase != .idle
          {
            Text("→ \(target)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Text(statusDetail)
          .font(.caption)
          .foregroundStyle(
            snapshot.phase == .failed
              ? StudioDesign.warning : .secondary
          )
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      if !snapshot.rawText.isEmpty {
        Button("Copy Raw") {
          model.copyLocalAITranscript(refined: false)
        }
        .buttonStyle(.bordered)
      }
      if !snapshot.refinedText.isEmpty {
        Button(snapshot.fallbackReason == nil ? "Copy Refined" : "Copy Edited") {
          model.copyLocalAITranscript(refined: true)
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(15)
    .studioCard(highlighted: snapshot.phase.isActive)
  }

  private var statusDetail: String {
    if let failure = snapshot.failure {
      return failure.recoveryMessage
    }
    if let fallback = snapshot.fallbackReason {
      return
        "The deterministic Edited transcript was inserted because refinement was unavailable: \(fallback.recoveryMessage)"
    }
    if !snapshot.volatileText.isEmpty {
      return snapshot.volatileText
    }
    switch snapshot.phase {
    case .idle:
      return readinessDetail
    case .preparing:
      return "Preparing on-device speech and the selected local model…"
    case .listening:
      return "Listening locally. Release the control when finished."
    case .finalizing:
      return "Finishing the raw on-device transcript…"
    case .refining:
      return "Correcting and formatting the transcript locally…"
    case .validating:
      return "Checking that protected text and target constraints are intact…"
    case .delivering:
      return "Inserting one final result…"
    case .canceling:
      return "Canceling without inserting text…"
    case .completed:
      return "The locally refined transcript was inserted successfully."
    case .failed:
      return "Local AI Dictation could not finish."
    }
  }

  private var readinessDetail: String {
    if model.localAIStyle.kind == .verbatim {
      return "Ready. Verbatim skips generative formatting."
    }
    return switch model.selectedLocalAIReadiness.state {
    case .checking:
      "Checking the selected local provider…"
    case .ready:
      "Ready. The model warms while you speak."
    case .unavailable(let detail):
      detail
    case .modelMissing(let name):
      "Install \(name) in Ollama or choose another provider in Settings."
    case .modelDigestChanged:
      "The selected Ollama model changed. Approve it again in Settings."
    }
  }
}

private struct DictationSetupView: View {
  let model: AppModel
  @State private var dictationSample = ""

  var body: some View {
    VStack(spacing: 14) {
      HStack(spacing: 0) {
        setupItem(
          icon: "waveform",
          title: "Local transcription",
          detail: dictationSetupDetail
        ) {
          StatusPill(
            title: dictationSetupStatus.title,
            systemImage: dictationSetupStatus.systemImage,
            color: dictationSetupStatus.color
          )
        }
      }

      Divider()

      HStack(spacing: 12) {
        Image(systemName: "text.cursor")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(StudioDesign.activeBlue)
          .frame(width: 34, height: 34)
          .background(
            StudioDesign.activeBlue.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 9)
          )

        VStack(alignment: .leading, spacing: 2) {
          Text("Dictation test")
            .font(
              .system(
                .subheadline,
                design: .default,
                weight: .semibold
              )
            )
          Text(
            "Click the field, hold the Local Dictation control while speaking, then release it."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        TextField(
          "Your dictated text appears here",
          text: $dictationSample
        )
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 230)
        .accessibilityLabel("Dictation test field")
      }
    }
    .padding(16)
    .studioCard()
  }

  private var dictationSetupDetail: String {
    guard model.hasLocalDictationAction else {
      return "Choose Local Dictation on a control to enable it."
    }
    guard model.canExecuteDictation else {
      return "Complete the permission cards above, then test it below."
    }
    if let failure = model.transcriptionPreparationFailure {
      return failure.recoveryMessage
    }
    if model.transcriptionPrepared {
      return "On-device recognition is ready; no macOS Dictation shortcut is used."
    }
    return "Preparing the on-device speech model…"
  }

  private var dictationSetupStatus: (title: String, systemImage: String, color: Color) {
    guard model.hasLocalDictationAction, model.canExecuteDictation else {
      return (
        "Setup needed",
        "exclamationmark.triangle.fill",
        StudioDesign.warning
      )
    }
    if model.transcriptionPreparationFailure != nil {
      return (
        "Unavailable",
        "exclamationmark.triangle.fill",
        StudioDesign.warning
      )
    }
    if model.transcriptionPrepared {
      return ("Ready", "checkmark.circle.fill", StudioDesign.accent)
    }
    return ("Preparing", "clock.fill", StudioDesign.activeBlue)
  }

  private func setupItem<Accessory: View>(
    icon: String,
    title: String,
    detail: String,
    @ViewBuilder accessory: () -> Accessory
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(StudioDesign.accent)
        .frame(width: 34, height: 34)
        .background(
          StudioDesign.accent.opacity(0.10),
          in: RoundedRectangle(cornerRadius: 9)
        )

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(
            .system(
              .subheadline,
              design: .default,
              weight: .semibold
            )
          )
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer()
      accessory()
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 14)
  }
}

extension TranscriptionPhase {
  fileprivate var displayTitle: String {
    switch self {
    case .idle:
      "Local Dictation ready"
    case .preparing:
      "Preparing"
    case .listening:
      "Listening"
    case .finalizing:
      "Finalizing"
    case .canceling:
      "Canceling"
    case .completed:
      "Transcription complete"
    case .failed:
      "Transcription needs attention"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .idle, .completed:
      "waveform.badge.checkmark"
    case .preparing:
      "ellipsis.circle.fill"
    case .listening:
      "waveform.circle.fill"
    case .finalizing:
      "text.badge.checkmark"
    case .canceling:
      "xmark.circle.fill"
    case .failed:
      "exclamationmark.triangle.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .idle, .completed:
      StudioDesign.accent
    case .preparing, .listening, .finalizing:
      StudioDesign.activeBlue
    case .canceling, .failed:
      StudioDesign.warning
    }
  }

  fileprivate var isActive: Bool {
    [.preparing, .listening, .finalizing, .canceling]
      .contains(self)
  }
}

extension TranscriptionFailure {
  var recoveryMessage: String {
    switch self {
    case .microphonePermissionDenied:
      "Allow Microphone access in System Settings."
    case .speechRecognitionPermissionDenied:
      "Allow Speech Recognition access in System Settings."
    case .localeUnsupported:
      "The current language is not supported by Apple's on-device recognizer."
    case .modelUnavailable:
      "The on-device speech model is not available. Check macOS language resources and try again."
    case .noFocusedTextField:
      "Select an editable text field before pressing the control."
    case .secureTextField:
      "For safety, transcription is never inserted into password fields."
    case .focusChanged:
      "The focused field changed, so insertion stopped safely."
    case .processChanged:
      "The target application changed, so insertion stopped safely."
    case .caretChanged:
      "The text cursor moved, so live insertion stopped safely."
    case .audioUnavailable(let message):
      "Microphone audio is unavailable: \(message)"
    case .recognitionFailed(let message):
      "On-device recognition failed: \(message)"
    case .insertionFailed:
      "The transcript could not be inserted into the selected field."
    }
  }
}

extension LocalAIDictationPhase {
  fileprivate var displayTitle: String {
    switch self {
    case .idle:
      "Local AI Dictation ready"
    case .preparing:
      "Preparing"
    case .listening:
      "Listening"
    case .finalizing:
      "Transcribing"
    case .refining:
      "Refining locally"
    case .validating:
      "Checking result"
    case .delivering:
      "Inserting"
    case .canceling:
      "Canceling"
    case .completed:
      "Local AI Dictation complete"
    case .failed:
      "Local AI Dictation needs attention"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .idle, .completed:
      "waveform.badge.checkmark"
    case .preparing:
      "ellipsis.circle.fill"
    case .listening:
      "waveform.circle.fill"
    case .finalizing:
      "text.badge.checkmark"
    case .refining, .validating:
      "sparkles"
    case .delivering:
      "text.cursor"
    case .canceling:
      "xmark.circle.fill"
    case .failed:
      "exclamationmark.triangle.fill"
    }
  }

  fileprivate var color: Color {
    switch self {
    case .idle, .completed:
      StudioDesign.accent
    case .preparing, .listening, .finalizing, .refining,
      .validating, .delivering:
      StudioDesign.activeBlue
    case .canceling, .failed:
      StudioDesign.warning
    }
  }

  fileprivate var isActive: Bool {
    ![.idle, .completed, .failed].contains(self)
  }
}

extension LocalAIDictationFailure {
  fileprivate var recoveryMessage: String {
    switch self {
    case .transcription(let failure):
      failure.recoveryMessage
    case .refinement(let failure):
      "Local refinement failed: \(failure.recoveryMessage)"
    case .delivery(let failure):
      failure.recoveryMessage
    }
  }
}

extension LocalAIRefinementFailure {
  fileprivate var recoveryMessage: String {
    switch self {
    case .providerUnavailable(let detail):
      detail
    case .modelMissing(let name):
      "The selected model \(name) is not installed."
    case .modelDigestChanged:
      "The selected Ollama model changed and must be approved again."
    case .timedOut:
      "The selected model exceeded the three-second refinement limit."
    case .invalidResponse(let detail):
      detail
    case .requestTooLarge:
      "The transcript or context exceeded the local request limit."
    case .generationFailed(let detail):
      detail
    }
  }
}
