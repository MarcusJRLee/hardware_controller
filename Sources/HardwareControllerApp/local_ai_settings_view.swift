import HardwareControllerCore
import SwiftUI

struct LocalAISettingsSection: View {
  let model: AppModel
  let preferencesModel: ApplicationPreferencesModel

  @State private var vocabularyEntry = ""
  @State private var spokenForm = ""
  @State private var replacement = ""

  var body: some View {
    Section("Local AI Dictation") {
      Picker("Formatting provider", selection: providerBinding) {
        Text("Apple On-Device")
          .tag(LocalAIProviderKind.appleOnDevice)
        Text("Ollama")
          .tag(LocalAIProviderKind.ollama)
      }
      .pickerStyle(.segmented)

      Picker("Style", selection: styleBinding) {
        ForEach(VoiceStyleKind.allCases, id: \.self) { kind in
          Text(styleTitle(kind)).tag(kind)
        }
      }
      Text(styleDescription(settings.style.kind))
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("Casing", selection: casingBinding) {
        ForEach(VoiceCasingPolicy.allCases, id: \.self) { policy in
          Text(casingTitle(policy)).tag(policy)
        }
      }
      Text(casingDescription(settings.effectiveCasingPolicy))
        .font(.caption)
        .foregroundStyle(.secondary)

      if settings.provider == .ollama {
        Picker("Formatting model", selection: modelBinding) {
          ForEach(modelOptions) { option in
            Text(modelTitle(option)).tag(option.name)
          }
        }

        Picker("Keep model loaded", selection: retentionBinding) {
          Text("5 minutes").tag(LocalAIModelRetention.recentUse)
          Text("Until app quits")
            .tag(LocalAIModelRetention.processLifetime)
        }
        Text(
          "At quit or model change, Hardware Controller unloads only a model it started; an already-running shared model is left alone."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Active pipeline")
          .font(.headline)
        LabeledContent("Speech provider", value: pipeline.speechProvider)
        LabeledContent("Speech model", value: pipeline.speechModel)
        LabeledContent(
          "Formatting provider",
          value: pipeline.formattingProvider
        )
        LabeledContent("Formatting model", value: pipeline.formattingModel)
        LabeledContent("Formatting output", value: pipeline.formattingOutput)
        LabeledContent("Effective casing", value: pipeline.effectiveCasing)
        LabeledContent("Validation", value: pipeline.validation)
        LabeledContent("Fallback", value: pipeline.fallback)
      }

      LabeledContent("Status") {
        HStack(spacing: 6) {
          Image(systemName: readinessSymbol)
          Text(readinessDetail)
        }
        .foregroundStyle(readinessColor)
      }

      HStack {
        Button("Refresh Status") {
          model.refreshLocalAIReadiness()
        }
        Button("Test Selected Provider") {
          model.testLocalAIProvider()
        }
        .disabled(
          !selectedReadiness.state.canRun
            || model.localAIProviderTest == .running
        )
        if let providerTestDetail {
          Text(providerTestDetail)
            .font(.caption)
            .foregroundStyle(providerTestColor)
        }
      }

      if case .modelDigestChanged = selectedReadiness.state,
        let installedModel = selectedInstalledModel
      {
        Button("Approve Installed Digest") {
          updateSettings {
            $0.ollamaModel = LocalAIModelSelection(
              name: installedModel.name,
              expectedDigest: installedModel.digest
            )
          }
        }
      }

      Toggle("Use nearby text from the focused field", isOn: contextBinding)
      Text(
        "Nearby text is bounded and used only for the current dictation. Single-line and compatibility targets never provide it."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      DisclosureGroup("Personal dictionary") {
        VStack(alignment: .leading, spacing: 14) {
          dictionaryVocabulary
          Divider()
          dictionaryReplacements
        }
        .padding(.vertical, 8)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Additional instructions")
        TextEditor(text: instructionsBinding)
          .font(.body)
          .frame(minHeight: 88)
          .overlay {
            RoundedRectangle(cornerRadius: 6)
              .stroke(.quaternary)
          }
        Text(
          "Optional workflow guidance. Accuracy, privacy, and prompt-safety rules always remain active."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Text(
        "Speech, context, and model output stay on this Mac. Ollama is contacted only through its fixed localhost endpoint; no cloud inference is used."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var dictionaryVocabulary: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Recognition vocabulary")
        .font(.headline)
      Text("Names and technical terms that should be recognized accurately.")
        .font(.caption)
        .foregroundStyle(.secondary)
      ForEach(settings.dictionary.vocabulary, id: \.self) { entry in
        HStack {
          Text(entry)
          Spacer()
          Button(role: .destructive) {
            updateSettings { settings in
              settings.dictionary.vocabulary.removeAll { $0 == entry }
            }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Remove \(entry)")
        }
      }
      HStack {
        TextField("Add a name or term", text: $vocabularyEntry)
          .dictionaryInputField()
          .accessibilityLabel("Recognition vocabulary entry")
          .onSubmit(addVocabularyEntry)
        Button("Add", action: addVocabularyEntry)
          .buttonStyle(.bordered)
          .disabled(normalizedVocabularyEntry.isEmpty)
      }
    }
  }

  private var dictionaryReplacements: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Exact replacements")
        .font(.headline)
      Text("Replace a spoken form after recognition, before refinement.")
        .font(.caption)
        .foregroundStyle(.secondary)
      ForEach(settings.dictionary.replacements) { item in
        HStack {
          Text("\(item.spokenForm) → \(item.replacement)")
          Spacer()
          Button(role: .destructive) {
            updateSettings { settings in
              settings.dictionary.replacements.removeAll {
                $0.id == item.id
              }
            }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Remove replacement for \(item.spokenForm)")
        }
      }
      HStack {
        TextField("Spoken form", text: $spokenForm)
          .dictionaryInputField()
          .accessibilityLabel("Spoken form")
          .onSubmit(addReplacement)
        Image(systemName: "arrow.right")
          .foregroundStyle(.secondary)
        TextField("Replacement", text: $replacement)
          .dictionaryInputField()
          .accessibilityLabel("Replacement")
          .onSubmit(addReplacement)
        Button("Add", action: addReplacement)
          .buttonStyle(.bordered)
          .disabled(
            normalizedSpokenForm.isEmpty
              || normalizedReplacement.isEmpty
          )
      }
    }
  }

  private var settings: LocalAISettings {
    preferencesModel.localAISettings
  }

  private var pipeline: LocalAIPipelinePresentation {
    LocalAIPipelinePresentation(settings: settings)
  }

  private var selectedReadiness: LocalAIProviderReadiness {
    model.localAIReadiness.readiness(for: settings.provider)
  }

  private var modelOptions: [LocalAIInstalledModel] {
    var options = selectedReadiness.models
    if !options.contains(where: { $0.name == settings.ollamaModel.name }) {
      options.append(
        LocalAIInstalledModel(
          name: settings.ollamaModel.name,
          digest: settings.ollamaModel.expectedDigest ?? "",
          sizeBytes: 0,
          isValidated: false,
          isRecommended:
            settings.ollamaModel.name
            == LocalAISettings.defaultRecommendedModelName
        )
      )
    }
    return options.sorted {
      if $0.isRecommended != $1.isRecommended {
        return $0.isRecommended
      }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  private var selectedInstalledModel: LocalAIInstalledModel? {
    selectedReadiness.models.first {
      $0.name == settings.ollamaModel.name
    }
  }

  private var providerBinding: SwiftUI.Binding<LocalAIProviderKind> {
    SwiftUI.Binding(
      get: { settings.provider },
      set: { provider in
        updateSettings { $0.provider = provider }
      }
    )
  }

  private var styleBinding: SwiftUI.Binding<VoiceStyleKind> {
    SwiftUI.Binding(
      get: { settings.style.kind },
      set: { kind in
        updateSettings { $0.style = VoiceStyle(kind: kind) }
      }
    )
  }

  private var casingBinding: SwiftUI.Binding<VoiceCasingPolicy> {
    SwiftUI.Binding(
      get: { settings.casingPolicy },
      set: { policy in
        updateSettings { $0.casingPolicy = policy }
      }
    )
  }

  private var modelBinding: SwiftUI.Binding<String> {
    SwiftUI.Binding(
      get: { settings.ollamaModel.name },
      set: { name in
        guard let model = modelOptions.first(where: { $0.name == name }) else {
          return
        }
        updateSettings {
          $0.ollamaModel = LocalAIModelSelection(
            name: model.name,
            expectedDigest: model.digest.isEmpty ? nil : model.digest
          )
        }
      }
    )
  }

  private var retentionBinding: SwiftUI.Binding<LocalAIModelRetention> {
    SwiftUI.Binding(
      get: { settings.modelRetention },
      set: { retention in
        updateSettings { $0.modelRetention = retention }
      }
    )
  }

  private var contextBinding: SwiftUI.Binding<Bool> {
    SwiftUI.Binding(
      get: { settings.includeNearbyText },
      set: { enabled in
        updateSettings { $0.includeNearbyText = enabled }
      }
    )
  }

  private var instructionsBinding: SwiftUI.Binding<String> {
    SwiftUI.Binding(
      get: { settings.additionalInstructions },
      set: { instructions in
        guard instructions.count <= 2_000 else {
          return
        }
        updateSettings { $0.additionalInstructions = instructions }
      }
    )
  }

  private var readinessSymbol: String {
    if settings.style.kind == .verbatim {
      return "checkmark.circle.fill"
    }
    return switch selectedReadiness.state {
    case .ready:
      "checkmark.circle.fill"
    case .checking:
      "clock"
    case .unavailable, .modelMissing, .modelDigestChanged:
      "exclamationmark.triangle.fill"
    }
  }

  private var readinessColor: Color {
    settings.style.kind == .verbatim || selectedReadiness.state.canRun
      ? .secondary : StudioDesign.warning
  }

  private var readinessDetail: String {
    if settings.style.kind == .verbatim {
      return "Not used by Verbatim Style"
    }
    return switch selectedReadiness.state {
    case .checking:
      "Checking…"
    case .ready:
      "Ready"
    case .unavailable(let detail):
      detail
    case .modelMissing(let name):
      "Install \(name) in Ollama, then refresh."
    case .modelDigestChanged:
      "The model changed. Select it again to approve the installed digest."
    }
  }

  private var providerTestDetail: String? {
    switch model.localAIProviderTest {
    case .idle:
      nil
    case .running:
      "Testing…"
    case .passed:
      "Test passed"
    case .failed(let failure):
      "Test failed: \(failure.settingsMessage)"
    }
  }

  private var providerTestColor: Color {
    model.localAIProviderTest == .passed
      ? StudioDesign.accent : StudioDesign.warning
  }

  private func modelTitle(_ model: LocalAIInstalledModel) -> String {
    var suffixes: [String] = []
    if model.isRecommended {
      suffixes.append("Recommended")
    } else if model.isValidated {
      suffixes.append("Validated")
    }
    if model.sizeBytes > 0 {
      suffixes.append(
        ByteCountFormatter.string(
          fromByteCount: Int64(clamping: model.sizeBytes),
          countStyle: .file
        )
      )
    }
    return suffixes.isEmpty
      ? model.name
      : "\(model.name) — \(suffixes.joined(separator: ", "))"
  }

  private func styleTitle(_ kind: VoiceStyleKind) -> String {
    switch kind {
    case .natural:
      "Natural"
    case .casualMessage:
      "Casual Message"
    case .formal:
      "Formal"
    case .technical:
      "Technical"
    case .verbatim:
      "Verbatim"
    }
  }

  private func styleDescription(_ kind: VoiceStyleKind) -> String {
    switch kind {
    case .natural:
      "Clear everyday writing that retains your voice."
    case .casualMessage:
      "Concise, lowercase conversational text for chats and messages."
    case .formal:
      "Professional grammar and complete sentences."
    case .technical:
      "Concise structure with commands and code preserved exactly."
    case .verbatim:
      "Recognition output with no generative rewriting."
    }
  }

  private func casingTitle(_ policy: VoiceCasingPolicy) -> String {
    switch policy {
    case .styleDefault:
      "Style Default"
    case .lowercaseProse:
      "Lowercase Prose"
    case .strictLowercase:
      "Strict Lowercase"
    }
  }

  private func casingDescription(_ policy: VoiceCasingPolicy) -> String {
    switch policy {
    case .styleDefault:
      "Follows the selected Style."
    case .lowercaseProse:
      "Lowercases prose while preserving names, acronyms, and operational tokens."
    case .strictLowercase:
      "Lowercases prose while preserving URLs, email addresses, paths, code tokens, quoted text, and Dictionary values."
    }
  }

  private var normalizedVocabularyEntry: String {
    vocabularyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var normalizedSpokenForm: String {
    spokenForm.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var normalizedReplacement: String {
    replacement.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func addVocabularyEntry() {
    let entry = normalizedVocabularyEntry
    guard !entry.isEmpty else {
      return
    }
    let saved = updateSettings { settings in
      settings.dictionary.vocabulary.append(entry)
    }
    if saved {
      vocabularyEntry = ""
    }
  }

  private func addReplacement() {
    let spokenForm = normalizedSpokenForm
    let replacement = normalizedReplacement
    guard !spokenForm.isEmpty, !replacement.isEmpty else {
      return
    }
    let saved = updateSettings { settings in
      settings.dictionary.replacements.append(
        PersonalDictionaryReplacement(
          spokenForm: spokenForm,
          replacement: replacement
        )
      )
    }
    if saved {
      self.spokenForm = ""
      self.replacement = ""
    }
  }

  @discardableResult
  private func updateSettings(
    _ mutation: (inout LocalAISettings) -> Void
  ) -> Bool {
    var candidate = settings
    mutation(&candidate)
    return preferencesModel.setLocalAISettings(candidate)
  }
}

extension View {
  /// Gives dictionary inputs an explicit editable-field affordance in a Form.
  fileprivate func dictionaryInputField() -> some View {
    textFieldStyle(.roundedBorder)
      .controlSize(.regular)
  }
}

extension LocalAIRefinementFailure {
  fileprivate var settingsMessage: String {
    switch self {
    case .providerUnavailable(let detail),
      .invalidResponse(let detail),
      .generationFailed(let detail):
      detail
    case .remoteProviderRejected:
      "Remote-capable providers are disabled in local-only mode."
    case .modelMissing(let name):
      "\(name) is not installed."
    case .modelDigestChanged:
      "The model digest changed. Select it again."
    case .timedOut:
      "The three-second deadline expired."
    case .requestTooLarge:
      "The local test request was too large."
    }
  }
}
