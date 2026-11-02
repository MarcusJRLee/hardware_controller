import HardwareControllerModelDownload
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
      ForEach(model.choices) { choice in
        VoiceInputModelChoiceRow(
          choice: choice,
          isBusy: model.isImporting || model.isRemoving,
          select: { installed in Task { await model.selectASRModel(installed) } },
          download: model.download,
          cancel: model.cancelDownload
        )
        .swipeActions {
          if let installed = choice.installed {
            Button("Remove", role: .destructive) { pendingRemoval = installed }
              .accessibilityIdentifier("remove_model_package")
          }
        }
      }
      if let errorMessage = model.errorMessage ?? pickerErrorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .accessibilityIdentifier("model_package_error")
      }
    } header: {
      Text("Speech model")
        .accessibilityIdentifier("local_model_library")
    } footer: {
      Text(
        "Speech never leaves this iPhone. Downloads come from pinned Hugging Face files, are checked against fixed checksums, and need no account."
      )
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
      Button("Remove", role: .destructive) {
        guard let installed = pendingRemoval else {
          return
        }
        pendingRemoval = nil
        Task { await model.removePackage(installed) }
      }
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
    } message: {
      Text("You can download it again later.")
    }

    Section {
      Button {
        isImporterPresented = true
      } label: {
        Label(
          model.isImporting ? "Importing…" : "Import from Files…",
          systemImage: "folder"
        )
      }
      .disabled(model.isImporting || model.isRemoving)
      .accessibilityIdentifier("import_model_package")
    } footer: {
      Text(
        "For a Model package folder made on a Mac with scripts/prepare_ios_asr_model_package.sh and copied into Files."
      )
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

private struct VoiceInputModelChoiceRow: View {
  let choice: VoiceInputModelChoice
  let isBusy: Bool
  let select: (VoiceInputInstalledModelPackage) -> Void
  let download: (ASRModelCatalogEntry) -> Void
  let cancel: (ASRModelCatalogEntry) -> Void

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(choice.title)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      accessory
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if case .installed(let installed) = choice.state, !isBusy {
        select(installed)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelectable ? .isButton : [])
    .accessibilityHint(isSelectable ? "Use for speech to text" : "")
    .accessibilityIdentifier("model_choice_\(choice.id)")
  }

  private var isSelectable: Bool {
    if case .installed = choice.state { return true }
    return false
  }

  private var subtitle: String {
    let size = ByteCountFormatter.string(fromByteCount: choice.bytes, countStyle: .file)
    return "\(choice.summary) · \(size)"
  }

  @ViewBuilder
  private var accessory: some View {
    switch choice.state {
    case .active:
      Image(systemName: "checkmark")
        .fontWeight(.semibold)
        .accessibilityLabel("Active")
        .accessibilityIdentifier("active_asr_model")
    case .installed:
      Text("Use")
        .foregroundStyle(.secondary)
    case .downloading(let entry, let fraction):
      HStack(spacing: 10) {
        ProgressView(value: fraction)
          .progressViewStyle(.circular)
          .accessibilityLabel("Downloading")
          .accessibilityValue("\(Int(fraction * 100)) percent")
        Button {
          cancel(entry)
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Cancel download")
        .accessibilityIdentifier("cancel_model_download")
      }
    case .available(let entry):
      Button("Download") { download(entry) }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(isBusy)
        .accessibilityIdentifier("download_model_\(entry.packageID)")
    }
  }
}
