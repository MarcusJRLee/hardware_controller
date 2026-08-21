import Foundation
import HardwareControllerCore
import HardwareControllerMac
import SwiftUI

struct ControlEditorView: View {
  let model: AppModel
  let control: ControlDescriptor
  let position: String
  var highlighted = false
  var profileID: UUID? = nil
  var configurationID: UUID? = nil

  private var controlID: ControlID {
    control.id
  }

  private var binding: HardwareControllerCore.Binding {
    if let profileID, let configurationID {
      return model.binding(
        for: controlID,
        profileID: profileID,
        configurationID: configurationID
      )
    }
    return model.binding(for: controlID)
  }

  private var allowsTesting: Bool {
    profileID == nil || profileID == model.activeProfile.id
  }

  private var resolvedConfigurationID: UUID? {
    configurationID
      ?? model.activeProfile.configuration(
        matching: DeviceMatchRule(
          modelID: model.defaultDeviceDescriptor.modelID
        )
      )?.id
  }

  private var keyboardFallbackFailure: KeyboardFallbackRegistrationFailure? {
    guard
      allowsTesting,
      let resolvedConfigurationID
    else {
      return nil
    }
    return model.keyboardFallbackFailure(
      for: controlID,
      configurationID: resolvedConfigurationID
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(position)
            .font(
              .system(
                .caption2,
                design: .monospaced,
                weight: .bold
              )
            )
            .foregroundStyle(
              highlighted ? StudioDesign.accent : .secondary
            )
          Text("\(control.name) control")
            .font(
              .system(
                .subheadline,
                design: .default,
                weight: .semibold
              )
            )
        }

        Spacer()

        Image(systemName: binding.action.kind.systemImage)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(
            highlighted ? StudioDesign.accent : .secondary
          )
          .frame(width: 32, height: 32)
          .background(
            (highlighted
              ? StudioDesign.accent
              : Color.secondary).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 9)
          )
      }

      VStack(alignment: .leading, spacing: 7) {
        fieldLabel("Action")

        Picker(
          "Action",
          selection: Binding(
            get: { binding.action.kind },
            set: { setAction($0) }
          )
        ) {
          ForEach(ActionKind.allCases, id: \.self) { kind in
            Label(kind.displayTitle, systemImage: kind.systemImage)
              .tag(kind)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if binding.action.kind.ownsDictationSession {
        VStack(alignment: .leading, spacing: 7) {
          fieldLabel("Behavior")

          Picker(
            "Behavior",
            selection: Binding(
              get: { binding.interactionMode },
              set: { setInteractionMode($0) }
            )
          ) {
            Text("Hold").tag(InteractionMode.momentary)
            Text("Toggle").tag(InteractionMode.toggle)
          }
          .labelsHidden()
          .pickerStyle(.segmented)
        }
      }

      if let shortcut = binding.action.shortcut,
        binding.action.kind != .noAction
      {
        VStack(alignment: .leading, spacing: 7) {
          fieldLabel(
            binding.action.kind.ownsDictationSession
              ? "Dictation shortcut"
              : "Shortcut"
          )

          ShortcutRecorderButton(
            shortcut: shortcut,
            onChange: { setShortcut($0) }
          )
        }
      }

      if binding.action.kind != .noAction {
        VStack(alignment: .leading, spacing: 7) {
          fieldLabel("Keyboard fallback")

          if let shortcut = binding.activationShortcut {
            HStack(spacing: 8) {
              ShortcutRecorderButton(
                shortcut: shortcut,
                onChange: { setActivationShortcut($0) }
              )

              Button("Clear") {
                setActivationShortcut(nil)
              }
              .buttonStyle(.borderless)
            }
          } else {
            Button("Use suggested ⌃⇧⌘D") {
              setActivationShortcut(.suggestedControlActivation)
            }
            .buttonStyle(.link)
          }

          Text(keyboardFallbackStatusText)
            .font(.caption2)
            .foregroundStyle(
              keyboardFallbackFailure == nil
                ? Color.secondary : StudioDesign.warning
            )
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 0)

      HStack(alignment: .bottom) {
        if binding.action.kind.ownsDictationSession {
          Text(
            binding.interactionMode == .momentary
              ? "Begins on press · ends on release"
              : "Press once to begin · again to end"
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        } else if binding.action.kind == .keyboardShortcut {
          Text("Runs once per press")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if binding.action.kind == .keyboardShortcut {
          Button {
            model.testBinding(controlID)
          } label: {
            Image(systemName: "play.fill")
          }
          .buttonStyle(.borderless)
          .help("Test this shortcut")
          .disabled(
            !allowsTesting || !model.canExecuteKeyboardShortcuts
          )
        } else if binding.action.kind.ownsDictationSession {
          Text("Test with the control below")
            .font(.caption2)
            .foregroundStyle(
              model.canExecuteDictation
                ? StudioDesign.accent
                : StudioDesign.warning
            )
        }
      }
      .frame(minHeight: 22)
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 330, alignment: .top)
    .studioCard(highlighted: highlighted)
  }

  private func fieldLabel(_ title: String) -> some View {
    Text(title.uppercased())
      .font(
        .system(
          .caption2,
          design: .rounded,
          weight: .bold
        )
      )
      .tracking(0.8)
      .foregroundStyle(.tertiary)
  }

  /// Routes an Action edit to active or identified Profile state.
  private func setAction(_ kind: ActionKind) {
    if let profileID, let configurationID {
      model.setAction(
        kind,
        for: controlID,
        profileID: profileID,
        configurationID: configurationID
      )
    } else {
      model.setAction(kind, for: controlID)
    }
  }

  /// Routes a mode edit to active or identified Profile state.
  private func setInteractionMode(_ mode: InteractionMode) {
    if let profileID, let configurationID {
      model.setInteractionMode(
        mode,
        for: controlID,
        profileID: profileID,
        configurationID: configurationID
      )
    } else {
      model.setInteractionMode(mode, for: controlID)
    }
  }

  /// Routes a shortcut edit to active or identified Profile state.
  private func setShortcut(
    _ shortcut: HardwareControllerCore.KeyboardShortcut
  ) {
    if let profileID, let configurationID {
      model.setShortcut(
        shortcut,
        for: controlID,
        profileID: profileID,
        configurationID: configurationID
      )
    } else {
      model.setShortcut(shortcut, for: controlID)
    }
  }

  /// Routes a fallback edit to active or identified Profile state.
  private func setActivationShortcut(
    _ shortcut: HardwareControllerCore.KeyboardShortcut?
  ) {
    if let profileID, let configurationID {
      model.setActivationShortcut(
        shortcut,
        for: controlID,
        profileID: profileID,
        configurationID: configurationID
      )
    } else {
      model.setActivationShortcut(shortcut, for: controlID)
    }
  }

  /// Explains activation scope or the active registration failure.
  private var keyboardFallbackStatusText: String {
    if let keyboardFallbackFailure {
      return keyboardFallbackFailure.recoveryMessage
    }
    if !allowsTesting {
      return "Available when this Profile is active."
    }
    return "Triggers this Control even when its Device is disconnected."
  }
}

extension ActionKind {
  var displayTitle: String {
    switch self {
    case .noAction:
      "No Action"
    case .dictation:
      "Local Dictation"
    case .localAIDictation:
      "Local AI Dictation"
    case .keyboardShortcut:
      "Keyboard Shortcut"
    }
  }

  var systemImage: String {
    switch self {
    case .noAction:
      "minus"
    case .dictation:
      "waveform"
    case .localAIDictation:
      "wand.and.stars"
    case .keyboardShortcut:
      "command"
    }
  }
}
