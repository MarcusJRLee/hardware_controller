import HardwareControllerVoiceFFI
import SwiftUI
import UniformTypeIdentifiers

/// Installed speech models, the active choice, import, and removal.
struct VoiceInputModelLibrarySection: View {
  @ObservedObject var model: VoiceInputModelLibraryModel
  @State private var isImporterPresented = false
  @State private var pendingRemoval: VoiceInputInstalledModelPackage?
  @State private var pickerErrorMessage: String?

  var body: some View {
    Section {
      if model.isPreparingStarter {
        LabeledContent("Installing built-in model") { ProgressView() }
      }
      ForEach(model.packages, id: \.rootURL) { installed in
        packageRow(installed)
      }
      Button {
        isImporterPresented = true
      } label: {
        Label(
          model.isImporting ? "Importing…" : "Import Model package…",
          systemImage: "square.and.arrow.down"
        )
      }
      .disabled(model.isImporting || model.isRemoving)
      .accessibilityIdentifier("import_model_package")

      if let errorMessage = model.errorMessage ?? pickerErrorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .accessibilityIdentifier("model_package_error")
      }
    } header: {
      Text("Speech model")
        .accessibilityIdentifier("local_model_library")
    } footer: {
      Text("Models are verified and stay in this app's private storage.")
    }
    .fileImporter(
      isPresented: $isImporterPresented,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false,
      onCompletion: handleSelection
    )
    .confirmationDialog(
      "Remove this model?",
      isPresented: removalConfirmationIsPresented,
      titleVisibility: .visible
    ) {
      Button("Remove installed copy", role: .destructive) {
        guard let installed = pendingRemoval else {
          return
        }
        pendingRemoval = nil
        Task { await model.removePackage(installed) }
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    } message: {
      Text("The original imported folder is not changed.")
    }
  }

  private func packageRow(_ installed: VoiceInputInstalledModelPackage) -> some View {
    let isActive = model.isActiveASRModel(installed)
    let canSelect = VoiceInputASRModelRegistry.isCompatible(installed.package) && !isActive
    return Button {
      guard canSelect else {
        return
      }
      Task { await model.selectASRModel(installed) }
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(installed.package.displayName)
            .foregroundStyle(.primary)
          Text(packageSummary(installed))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if isActive {
          Image(systemName: "checkmark")
            .accessibilityLabel("Active")
            .accessibilityIdentifier("active_asr_model")
        }
      }
    }
    .disabled(model.isImporting || model.isRemoving)
    .accessibilityHint(canSelect ? "Use for speech to text" : "")
    .accessibilityIdentifier(canSelect ? "select_asr_model" : "model_package_card")
    .swipeActions {
      Button("Remove", role: .destructive) { pendingRemoval = installed }
        .accessibilityIdentifier("remove_model_package")
    }
    .contextMenu {
      Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = installed }
    }
  }

  private func packageSummary(_ installed: VoiceInputInstalledModelPackage) -> String {
    let package = installed.package
    let languages =
      package.languages.isEmpty ? "No declared language" : package.languages.joined(separator: ", ")
    let bytes = ByteCountFormatter.string(
      fromByteCount: Int64(clamping: package.verifiedBytes),
      countStyle: .file
    )
    let provenance = installed.publisherVerified ? "Verified" : "Manual import"
    return "\(languages) · \(bytes) · \(provenance)"
  }

  private func handleSelection(_ result: Result<[URL], Error>) {
    pickerErrorMessage = nil
    switch result {
    case .success(let urls):
      guard let source = urls.first else {
        pickerErrorMessage = "Choose one Model package folder."
        return
      }
      Task { await model.importPackage(from: source) }
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
