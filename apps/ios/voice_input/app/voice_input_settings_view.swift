import AppIntents
import HardwareControllerCore
import SwiftUI

struct VoiceInputSettingsView: View {
  @ObservedObject var model: VoiceInputAppModel
  @ObservedObject var modelLibrary: VoiceInputModelLibraryModel
  @ObservedObject var history: VoiceInputHistoryModel
  let openSettings: () -> Void

  var body: some View {
    NavigationStack {
      Form {
        VoiceInputSetupSection(
          microphoneAuthorization: model.microphoneAuthorization,
          keyboardHandoffObserved: model.keyboardHandoffObserved,
          errorMessage: model.onboardingErrorMessage,
          requestMicrophone: model.requestMicrophone,
          openSettings: openSettings
        )
        VoiceInputModelLibrarySection(model: modelLibrary)
        VoiceInputHistoryStorageSection(model: history)
        Section {
          ShortcutsLink()
            .accessibilityIdentifier("open_voice_shortcuts")
        } header: {
          Text("Without the keyboard")
        } footer: {
          Text(
            "Add Voice Capture to Control Center, the Lock Screen, or the Action button, or ask Siri. A Live Activity shows while recording continues in the background."
          )
        }
        Section {
          NavigationLink("Third-party notices") { VoiceInputNoticesView() }
        } footer: {
          Text(
            "Audio, transcripts, and models never leave this iPhone. No account, analytics, or network access."
          )
        }
      }
      .navigationTitle("Settings")
    }
  }
}

private struct VoiceInputHistoryStorageSection: View {
  @ObservedObject var model: VoiceInputHistoryModel

  var body: some View {
    Section {
      Picker("Keep audio for", selection: ageBinding) {
        Text("Don't keep").tag(Int?.some(0))
        Text("30 days").tag(Int?.some(30))
        Text("90 days").tag(Int?.some(90))
        Text("1 year").tag(Int?.some(365))
        Text("Forever").tag(Int?.none)
      }
      .accessibilityIdentifier("history_retention_age")
      Picker("Audio up to", selection: byteBinding) {
        Text("Don't keep").tag(Int64?.some(0))
        Text("512 MiB").tag(Int64?.some(512 * 1_024 * 1_024))
        Text("1 GiB").tag(Int64?.some(1_024 * 1_024 * 1_024))
        Text("2 GiB").tag(Int64?.some(2 * 1_024 * 1_024 * 1_024))
        Text("Unlimited").tag(Int64?.none)
      }
      .accessibilityIdentifier("history_retention_size")
      Picker("Recordings", selection: countBinding) {
        Text("Don't keep").tag(Int?.some(0))
        Text("500").tag(Int?.some(500))
        Text("2,000").tag(Int?.some(2_000))
        Text("5,000").tag(Int?.some(5_000))
        Text("Unlimited").tag(Int?.none)
      }
      .accessibilityIdentifier("history_retention_count")
      if let maintenanceMessage = model.maintenanceMessage {
        Label(maintenanceMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("history_storage_status")
      }
    } header: {
      Text("History storage")
        .accessibilityIdentifier("history_storage")
    } footer: {
      Text(
        "The first limit reached, or less than 1 GiB free, removes the oldest unpinned audio. Transcripts stay searchable."
      )
    }
    .disabled(!model.canUpdateRetention || model.isUpdatingRetention)
  }

  private var ageBinding: Binding<Int?> {
    binding(\.maximumAgeDays) { settings, value in
      VoiceHistoryRetentionSettings(
        maximumAgeDays: value,
        maximumAudioBytes: settings.maximumAudioBytes,
        maximumArtifactCount: settings.maximumArtifactCount
      )
    }
  }

  private var byteBinding: Binding<Int64?> {
    binding(\.maximumAudioBytes) { settings, value in
      VoiceHistoryRetentionSettings(
        maximumAgeDays: settings.maximumAgeDays,
        maximumAudioBytes: value,
        maximumArtifactCount: settings.maximumArtifactCount
      )
    }
  }

  private var countBinding: Binding<Int?> {
    binding(\.maximumArtifactCount) { settings, value in
      VoiceHistoryRetentionSettings(
        maximumAgeDays: settings.maximumAgeDays,
        maximumAudioBytes: settings.maximumAudioBytes,
        maximumArtifactCount: value
      )
    }
  }

  private func binding<Value>(
    _ keyPath: KeyPath<VoiceHistoryRetentionSettings, Value>,
    replacing: @escaping (VoiceHistoryRetentionSettings, Value) -> VoiceHistoryRetentionSettings
  ) -> Binding<Value> {
    Binding(
      get: { model.retentionSettings[keyPath: keyPath] },
      set: { value in
        let settings = replacing(model.retentionSettings, value)
        Task { await model.updateRetentionSettings(settings) }
      }
    )
  }
}

private struct VoiceInputNoticesView: View {
  var body: some View {
    ScrollView {
      Text(notices)
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .padding()
    }
    .navigationTitle("Third-party notices")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var notices: String {
    guard
      let url = Bundle.main.url(forResource: "third_party_notices", withExtension: "txt"),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else {
      return "Notices are unavailable in this build."
    }
    return text
  }
}
