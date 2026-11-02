import SwiftUI
import VoiceInputShared

/// The one workflow screen: the newest text above, one record button below.
struct VoiceInputDictateView: View {
  @ObservedObject var model: VoiceInputAppModel
  @ObservedObject var modelLibrary: VoiceInputModelLibraryModel
  let openSettings: () -> Void
  @State private var recordingStartedAt: Date?
  @State private var copied = false
  private let localClipboard = VoiceInputSystemLocalClipboard()

  private var presentation: VoiceInputDictationPresentation {
    VoiceInputDictationPresentation(
      .init(
        phase: model.snapshot.phase,
        text: model.snapshot.text,
        microphone: model.microphoneAuthorization,
        isPreparingModel: modelLibrary.isPreparingStarter,
        hasSpeechModel: modelLibrary.activeASRModel != nil,
        errorMessage: model.errorMessage ?? model.snapshotErrorMessage
          ?? modelLibrary.errorMessage,
        lifecycleMessage: model.lifecycleMessage
      )
    )
  }

  var body: some View {
    let presentation = presentation
    NavigationStack {
      VStack(spacing: 0) {
        resultArea(presentation.result)
        controls(presentation)
      }
      .navigationTitle("Dictate")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) { styleMenu }
      }
      .onChange(of: model.snapshot.phase, initial: true) { _, phase in
        recordingStartedAt = phase == .recording ? (recordingStartedAt ?? .now) : nil
        copied = false
      }
    }
  }

  @ViewBuilder
  private func resultArea(_ result: String?) -> some View {
    if let result {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(result)
            .font(.title3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("dictation_result")
          HStack(spacing: 20) {
            Button {
              copy(result)
            } label: {
              Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .accessibilityIdentifier("dictation_copy")
            ShareLink(item: result) {
              Label("Share", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("dictation_share")
          }
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
        .padding(24)
      }
    } else {
      Spacer(minLength: 24)
    }
  }

  private func controls(_ presentation: VoiceInputDictationPresentation) -> some View {
    VStack(spacing: 20) {
      VStack(spacing: 6) {
        Text(presentation.title)
          .font(.title2.weight(.semibold))
          .accessibilityIdentifier("dictation_title")
        Text(presentation.detail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .accessibilityIdentifier("dictation_detail")
        // The timer line is always laid out so starting never shifts the
        // button, but it only ticks while recording so an idle app stays idle.
        Group {
          if let recordingStartedAt {
            TimelineView(.periodic(from: recordingStartedAt, by: 1)) { context in
              Text(
                Duration.seconds(context.date.timeIntervalSince(recordingStartedAt)),
                format: .time(pattern: .minuteSecond)
              )
            }
          } else {
            Text(Duration.zero, format: .time(pattern: .minuteSecond)).hidden()
          }
        }
        .font(.subheadline.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      }
      VoiceInputRecordButton(presentation: presentation, perform: perform)
    }
    .padding(.horizontal, 24)
    .padding(.top, 16)
    .padding(.bottom, 32)
    .frame(maxWidth: .infinity)
  }

  private var styleMenu: some View {
    Menu {
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
    } label: {
      Text(model.selectedStyleKind.displayName)
    }
    .accessibilityLabel("Style")
    .accessibilityValue(model.selectedStyleKind.displayName)
    .accessibilityIdentifier("capture_style")
  }

  private func perform(_ action: VoiceInputDictationPresentation.Action) {
    switch action {
    case .start:
      model.start()
    case .stop:
      model.stop()
    case .requestMicrophone:
      Task {
        await model.applyMicrophoneRequest()
        if model.microphoneAuthorization == .authorized {
          model.start()
        }
      }
    case .openSettings:
      openSettings()
    case .unavailable:
      break
    }
  }

  private func copy(_ text: String) {
    do {
      try localClipboard.copy(text)
      copied = true
    } catch {
      copied = false
    }
  }
}

/// Neutral at rest; the signal amber appears only while recording.
private struct VoiceInputRecordButton: View {
  let presentation: VoiceInputDictationPresentation
  let perform: (VoiceInputDictationPresentation.Action) -> Void
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    Button {
      perform(presentation.action)
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(presentation.isActive ? Color.black : Color(.systemBackground))
        .frame(width: 88, height: 88)
        .background(
          Circle().fill(
            presentation.isActive ? Color(uiColor: VoiceInputTheme.signal) : Color.primary)
        )
        .overlay {
          if contrast == .increased {
            Circle().strokeBorder(Color.primary, lineWidth: 2)
          }
        }
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .opacity(presentation.action == .unavailable ? 0.35 : 1)
    .disabled(presentation.action == .unavailable)
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
  }

  private var symbol: String {
    presentation.action == .stop ? "stop.fill" : "mic.fill"
  }

  private var label: String {
    switch presentation.action {
    case .stop: "Stop dictation"
    case .openSettings: "Open microphone settings"
    case .start, .requestMicrophone, .unavailable: "Start dictation"
    }
  }

  /// Stable identifiers for UI tests: one per reachable role.
  private var identifier: String {
    presentation.action == .stop ? "stop_capture" : "start_capture"
  }
}
