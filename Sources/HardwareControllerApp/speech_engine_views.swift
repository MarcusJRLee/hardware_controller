import HardwareControllerCore
import SwiftUI

/// Shown until the default engine can run; Dictation refuses to start meanwhile.
struct SpeechSetupCard: View {
  let speech: SpeechEngineModel

  @State private var confirmingApple = false

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: "waveform.badge.exclamationmark")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(StudioDesign.warning)
        .frame(width: 42, height: 42)
        .background(StudioDesign.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

      VStack(alignment: .leading, spacing: 3) {
        Text("Download the speech model to dictate")
          .font(.system(.subheadline, design: .default, weight: .semibold))
        Text(
          "Dictation uses \(speech.modelName), which runs entirely on this Mac and is more accurate than Apple's recognizer. It needs a one-time \(speech.downloadSize) download. Dictation stays off until you download it or choose Apple."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        SpeechDownloadStatus(speech: speech)
      }

      Spacer(minLength: 12)

      VStack(alignment: .trailing, spacing: 6) {
        if speech.isDownloading {
          Button("Cancel", action: speech.cancelDownload)
        } else {
          Button("Download \(speech.downloadSize)", action: speech.startDownload)
            .buttonStyle(.borderedProminent)
          Button("Use Apple Instead") { confirmingApple = true }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(15)
    .background(
      StudioDesign.warning.opacity(0.08),
      in: RoundedRectangle(cornerRadius: StudioDesign.compactCornerRadius, style: .continuous)
    )
    .appleConfirmation(isPresented: $confirmingApple, speech: speech)
  }
}

/// Settings for the speech engine and its Model package.
struct SpeechEngineSection: View {
  let model: AppModel
  let speech: SpeechEngineModel

  @State private var confirmingApple = false

  var body: some View {
    Section("Speech recognition") {
      Picker("Engine", selection: engineBinding) {
        Text("\(speech.modelName) (recommended)").tag(SpeechEngine.transcribeCpp)
        Text("Apple").tag(SpeechEngine.apple)
      }
      .pickerStyle(.segmented)

      switch speech.selection {
      case .transcribeCpp:
        if let package = speech.installedPackage {
          LabeledContent("Model", value: "\(package.displayName) · \(package.version)")
          Button("Remove Model", role: .destructive, action: speech.removeModel)
        } else {
          Text("Dictation is off until the \(speech.downloadSize) model is downloaded.")
            .foregroundStyle(StudioDesign.warning)
          HStack {
            if speech.isDownloading {
              Button("Cancel Download", action: speech.cancelDownload)
            } else {
              Button("Download \(speech.downloadSize)", action: speech.startDownload)
                .buttonStyle(.borderedProminent)
            }
          }
          SpeechDownloadStatus(speech: speech)
        }
      case .apple:
        Text(
          "Apple's recognizer is in use. It is less accurate than \(speech.modelName), which also runs entirely on this Mac."
        )
        .foregroundStyle(StudioDesign.warning)
      }

      if let notice = fallbackNotice {
        Text(notice)
          .font(.caption)
          .foregroundStyle(StudioDesign.warning)
      }
    }
    .appleConfirmation(isPresented: $confirmingApple, speech: speech)
  }

  private var engineBinding: SwiftUI.Binding<SpeechEngine> {
    SwiftUI.Binding(
      get: { speech.selection },
      set: { engine in
        if engine == .apple {
          confirmingApple = true
        } else {
          speech.select(engine)
        }
      }
    )
  }

  private var fallbackNotice: String? {
    guard speech.selection == .transcribeCpp else {
      return nil
    }
    return switch model.speechEngineFallback {
    case .serviceFailed:
      "The last session used Apple because the \(speech.modelName) service stopped unexpectedly."
    case .disabledUntilRelaunch:
      "\(speech.modelName) stopped twice, so Apple is in use until you quit and reopen Hardware Controller."
    case nil:
      nil
    }
  }
}

/// Download progress or the last failure, if any.
private struct SpeechDownloadStatus: View {
  let speech: SpeechEngineModel

  var body: some View {
    switch speech.downloadState {
    case .idle:
      EmptyView()
    case .downloading(let progress):
      ProgressView(value: progress.fraction) {
        Text(
          "\(ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))"
        )
        .font(.caption)
      }
      .frame(maxWidth: 320)
    case .failed(let message):
      Text(message)
        .font(.caption)
        .foregroundStyle(StudioDesign.warning)
    }
  }
}

extension View {
  /// Switching to Apple names the accuracy cost and needs a deliberate yes.
  fileprivate func appleConfirmation(isPresented: SwiftUI.Binding<Bool>, speech: SpeechEngineModel)
    -> some View
  {
    confirmationDialog(
      "Use Apple speech recognition?", isPresented: isPresented, titleVisibility: .visible
    ) {
      Button("Use Apple") { speech.select(.apple) }
      Button("Keep \(speech.modelName)", role: .cancel) {}
    } message: {
      Text(
        "Apple's recognizer is less accurate than \(speech.modelName). You can switch back in General settings at any time."
      )
    }
  }
}
