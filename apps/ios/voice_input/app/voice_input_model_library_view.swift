import HardwareControllerVoiceFFI
import SwiftUI
import UniformTypeIdentifiers

struct VoiceInputModelLibraryView: View {
  @ObservedObject var model: VoiceInputModelLibraryModel
  @State private var isImporterPresented = false
  @State private var pendingRemoval: VoiceInputInstalledModelPackage?
  @State private var pickerErrorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Local models")
          .font(.title2.bold())
          .accessibilityIdentifier("local_model_library")
        Text("Validated packages stay in this app's private storage.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      if model.packages.isEmpty {
        Text("No Model packages imported.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.packages, id: \.rootURL) { installed in
          packageCard(installed)
        }
      }

      Button {
        isImporterPresented = true
      } label: {
        Label(
          model.isImporting ? "Importing package" : "Import Model package",
          systemImage: "square.and.arrow.down"
        )
      }
      .buttonStyle(.bordered)
      .disabled(model.isImporting || model.isRemoving)
      .accessibilityIdentifier("import_model_package")

      if let errorMessage = model.errorMessage ?? pickerErrorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .accessibilityIdentifier("model_package_error")
      }
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false,
      onCompletion: handleSelection
    )
    .confirmationDialog(
      "Remove Model package?",
      isPresented: removalConfirmationIsPresented,
      titleVisibility: .visible
    ) {
      Button("Remove installed copy", role: .destructive) {
        guard let installed = pendingRemoval else {
          return
        }
        pendingRemoval = nil
        Task {
          await model.removePackage(installed)
        }
      }
      Button("Cancel", role: .cancel) {
        pendingRemoval = nil
      }
    } message: {
      Text("The original imported folder is not changed.")
    }
  }

  private func packageCard(
    _ installed: VoiceInputInstalledModelPackage
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text(installed.package.displayName)
          .font(.headline)
        Spacer()
        if model.isActiveASRModel(installed) {
          Text("Active")
            .font(.caption.bold())
            .accessibilityIdentifier("active_asr_model")
        }
        Text("v\(installed.package.version)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Text(packageSummary(installed.package))
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text(installed.publisherVerified ? "Pinned manifest" : "Manual import")
        .font(.caption)
        .foregroundStyle(.secondary)
      if canSelectForASR(installed.package) && !model.isActiveASRModel(installed) {
        Button {
          Task {
            await model.selectASRModel(installed)
          }
        } label: {
          Label("Use for speech to text", systemImage: "checkmark.circle")
        }
        .disabled(model.isImporting || model.isRemoving)
        .accessibilityIdentifier("select_asr_model")
      }
      Button(role: .destructive) {
        pendingRemoval = installed
      } label: {
        Label(
          model.isRemoving ? "Removing package" : "Remove package",
          systemImage: "trash"
        )
      }
      .disabled(model.isImporting || model.isRemoving)
      .accessibilityIdentifier("remove_model_package")
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      .quaternary,
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .accessibilityIdentifier("model_package_card")
  }

  private func canSelectForASR(_ package: PortableModelPackage) -> Bool {
    package.runtime == .whisperCPP
      && package.stage == .asr
      && package.capabilities.contains(.fileASR)
  }

  private func packageSummary(_ package: PortableModelPackage) -> String {
    let languages =
      package.languages.isEmpty
      ? "No declared language"
      : package.languages.joined(separator: ", ")
    let bytes = ByteCountFormatter.string(
      fromByteCount: Int64(clamping: package.verifiedBytes),
      countStyle: .file
    )
    return "\(stageName(package.stage)) · \(runtimeName(package.runtime)) · \(languages) · \(bytes)"
  }

  private func stageName(_ stage: PortableModelStage) -> String {
    switch stage {
    case .asr: "Speech to text"
    case .formatting: "Formatting"
    case .vad: "Voice activity"
    }
  }

  private func runtimeName(_ runtime: PortableModelRuntime) -> String {
    switch runtime {
    case .sherpaONNX: "sherpa-onnx"
    case .whisperCPP: "whisper.cpp"
    case .mistralRS: "mistral.rs"
    case .llamaCPP: "llama.cpp"
    }
  }

  private func handleSelection(_ result: Result<[URL], Error>) {
    pickerErrorMessage = nil
    switch result {
    case .success(let urls):
      guard let source = urls.first else {
        pickerErrorMessage = "Choose one Model package folder."
        return
      }
      Task {
        await model.importPackage(from: source)
      }
    case .failure:
      pickerErrorMessage = "The Model package picker did not return a folder."
    }
  }

  private var removalConfirmationIsPresented: Binding<Bool> {
    Binding(
      get: { pendingRemoval != nil },
      set: { isPresented in
        if !isPresented {
          pendingRemoval = nil
        }
      }
    )
  }
}
