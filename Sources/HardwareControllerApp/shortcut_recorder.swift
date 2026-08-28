import AppKit
import HardwareControllerCore
import SwiftUI

struct ShortcutRecorderButton: View {
  let shortcut: HardwareControllerCore.KeyboardShortcut?
  let onChange: (HardwareControllerCore.KeyboardShortcut) -> Void

  @State private var isRecording = false
  @State private var eventMonitor: Any?

  var body: some View {
    Button {
      isRecording ? stopRecording() : startRecording()
    } label: {
      HStack {
        Image(
          systemName: isRecording
            ? "circle.fill"
            : "keyboard"
        )
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(
          isRecording ? Color.red : StudioDesign.accent
        )

        Text(
          isRecording
            ? "Press shortcut…"
            : shortcut?.displayName ?? "Not set"
        )
        .font(
          .system(
            .caption,
            design: .rounded,
            weight: .semibold
          )
        )
        .monospacedDigit()

        Spacer()

        Text(isRecording ? "esc to cancel" : "Record")
          .font(
            .system(
              .caption2,
              design: .default,
              weight: .medium
            )
          )
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 10)
      .frame(height: 32)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      Color.primary.opacity(0.055),
      in: RoundedRectangle(
        cornerRadius: 8,
        style: .continuous
      )
    )
    .overlay {
      RoundedRectangle(
        cornerRadius: 8,
        style: .continuous
      )
      .strokeBorder(
        isRecording
          ? Color.red.opacity(0.35)
          : Color.primary.opacity(0.08)
      )
    }
    .onDisappear {
      stopRecording()
    }
    .accessibilityLabel("Keyboard shortcut")
    .accessibilityValue(
      isRecording
        ? "Recording"
        : shortcut?.displayName
          ?? "Not set"
    )
  }

  private func startRecording() {
    stopRecording()
    isRecording = true

    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: .keyDown
    ) { event in
      if event.keyCode == 53 {
        stopRecording()
        return nil
      }

      onChange(
        HardwareControllerCore.KeyboardShortcut(
          keyCode: event.keyCode,
          modifiers: event.modifierFlags.keyModifiers
        )
      )
      stopRecording()
      return nil
    }
  }

  private func stopRecording() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    isRecording = false
  }
}

extension NSEvent.ModifierFlags {
  fileprivate var keyModifiers: Set<KeyModifier> {
    var result: Set<KeyModifier> = []
    let flags = intersection(.deviceIndependentFlagsMask)

    if flags.contains(.command) {
      result.insert(.command)
    }
    if flags.contains(.option) {
      result.insert(.option)
    }
    if flags.contains(.shift) {
      result.insert(.shift)
    }
    if flags.contains(.control) {
      result.insert(.control)
    }
    if flags.contains(.function) {
      result.insert(.function)
    }
    return result
  }
}

extension HardwareControllerCore.KeyboardShortcut {
  var displayName: String {
    let ordered: [(KeyModifier, String)] = [
      (.control, "⌃"),
      (.option, "⌥"),
      (.shift, "⇧"),
      (.command, "⌘"),
      (.function, "fn "),
    ]
    let prefix =
      ordered
      .filter { modifiers.contains($0.0) }
      .map(\.1)
      .joined()
    return prefix + KeyCodeName.name(for: keyCode)
  }
}

private enum KeyCodeName {
  static func name(for keyCode: UInt16) -> String {
    names[keyCode] ?? "Key \(keyCode)"
  }

  private static let names: [UInt16: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G",
    6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
    13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
    18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
    23: "5", 24: "=", 25: "9", 26: "7", 27: "−",
    28: "8", 29: "0", 30: "]", 31: "O", 32: "U",
    33: "[", 34: "I", 35: "P", 36: "Return", 37: "L",
    38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
    43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
    48: "Tab", 49: "Space", 50: "`", 51: "Delete",
    53: "Escape", 65: "·", 76: "Enter", 96: "F5",
    97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
    103: "F11", 109: "F10", 111: "F12", 115: "Home",
    116: "Page Up", 117: "Forward Delete", 118: "F4",
    119: "End", 120: "F2", 121: "Page Down", 122: "F1",
    123: "←", 124: "→", 125: "↓", 126: "↑",
  ]
}
