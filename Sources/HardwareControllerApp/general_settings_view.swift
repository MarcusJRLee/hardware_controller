import SwiftUI

/// Presents application-wide appearance and startup preferences.
struct GeneralSettingsView: View {
  let model: AppModel
  let preferencesModel: ApplicationPreferencesModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 5) {
          Text("General")
            .font(.largeTitle.weight(.semibold))
          Text(
            "Choose how Hardware Controller looks, starts, and handles Dictation."
          )
          .foregroundStyle(.secondary)
        }

        if let notice = preferencesModel.recoveryNotice
          ?? preferencesModel.lastError
        {
          NoticeBanner(
            message: notice,
            dismiss: preferencesModel.clearNotice
          )
        }

        if let failure = model.voiceShortcutFailure {
          NoticeBanner(
            message: failure.recoveryMessage,
            dismiss: nil
          )
        }

        Form {
          Section("Appearance") {
            Picker(
              "Appearance",
              selection: Binding(
                get: { preferencesModel.appearance },
                set: { preferencesModel.setAppearance($0) }
              )
            ) {
              ForEach(ApplicationAppearance.allCases, id: \.self) {
                appearance in
                Text(appearance.title).tag(appearance)
              }
            }
            .pickerStyle(.segmented)

            Text("System follows this Mac’s appearance.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Section("Startup") {
            Toggle(
              "Launch at Login",
              isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
              )
            )
            .toggleStyle(.switch)
            .disabled(!model.canManageLaunchAtLogin)

            Text(startupDetail)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Section("Dictation microphone") {
            Picker(
              "Microphone",
              selection: Binding<String?>(
                get: { preferencesModel.preferredMicrophone?.id },
                set: {
                  preferencesModel.setPreferredMicrophone(
                    uniqueID: $0
                  )
                }
              )
            ) {
              Text("System Default").tag(String?.none)
              ForEach(preferencesModel.microphoneOptions) { microphone in
                Text(preferencesModel.microphoneTitle(microphone))
                  .tag(String?.some(microphone.id))
              }
            }

            Text(preferencesModel.microphoneStatusDetail)
              .font(.caption)
              .foregroundStyle(
                preferencesModel.microphoneDiscoveryError == nil
                  ? .secondary : StudioDesign.warning
              )
          }

          Section("Voice capture shortcut") {
            ShortcutRecorderButton(
              shortcut: preferencesModel.voiceTriggerSettings.shortcut
            ) { shortcut in
              var settings = preferencesModel.voiceTriggerSettings
              settings.shortcut = shortcut
              _ = preferencesModel.setVoiceTriggerSettings(settings)
            }

            if preferencesModel.voiceTriggerSettings.shortcut != nil {
              Button("Clear shortcut", role: .destructive) {
                var settings = preferencesModel.voiceTriggerSettings
                settings.shortcut = nil
                _ = preferencesModel.setVoiceTriggerSettings(settings)
              }
              .buttonStyle(.link)
            }

            Text(
              "Hold the chord while speaking, or press it twice to keep listening. Press it twice again to finish. Use at least two modifier keys."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }

          LocalAISettingsSection(
            model: model,
            preferencesModel: preferencesModel
          )
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
      }
      .padding(32)
      .frame(maxWidth: 820)
      .frame(maxWidth: .infinity, alignment: .top)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .task {
      preferencesModel.refreshMicrophones()
    }
  }

  private var startupDetail: String {
    if model.canManageLaunchAtLogin {
      return "Keep controller input ready after you sign in."
    }
    return
      "Move Hardware Controller to Applications before enabling Launch at Login."
  }

}
