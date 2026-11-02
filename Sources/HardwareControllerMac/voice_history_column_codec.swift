import Foundation
import HardwareControllerCore

/// Pure encoding and validation of Voice History JSON and enum columns, kept
/// apart from SQLite so schema evidence rules change and test independently.
enum VoiceHistoryColumnCodec {
  static func optionalAudioExpirationReason(
    _ rawValue: String?
  ) throws -> VoiceHistoryAudioExpirationReason? {
    guard let rawValue else {
      return nil
    }
    guard let reason = VoiceHistoryAudioExpirationReason(rawValue: rawValue)
    else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains an invalid audio expiration reason."
      )
    }
    return reason
  }

  static func optionalRecoveryKind(
    _ rawValue: String?
  ) throws -> VoiceHistoryRecoveryKind? {
    guard let rawValue else {
      return nil
    }
    guard let kind = VoiceHistoryRecoveryKind(rawValue: rawValue) else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains an invalid recovery kind."
      )
    }
    return kind
  }

  static func optionalUUID(_ value: String?) throws -> UUID? {
    guard let value else {
      return nil
    }
    guard let id = UUID(uuidString: value) else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains an invalid result relationship."
      )
    }
    return id
  }

  static func historyStyle(
    kind: String?,
    revision: Int?
  ) throws -> VoiceStyle? {
    guard kind != nil || revision != nil else {
      return nil
    }
    guard
      let kind,
      let revision,
      let styleKind = VoiceStyleKind(rawValue: kind),
      revision > 0
    else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid Style evidence."
      )
    }
    return VoiceStyle(kind: styleKind, revision: revision)
  }

  static func historyProvider(
    _ value: String?
  ) throws -> LocalAIProviderKind? {
    guard let value else {
      return nil
    }
    guard let provider = LocalAIProviderKind(rawValue: value) else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid provider evidence."
      )
    }
    return provider
  }

  static func historyDeliveryOutcome(
    _ value: String?
  ) throws -> VoiceSessionDeliveryOutcome? {
    guard let value else {
      return nil
    }
    guard let outcome = VoiceSessionDeliveryOutcome(rawValue: value) else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid delivery-result evidence."
      )
    }
    return outcome
  }

  static func historyFormattedDocument(
    from json: String?,
    expectedText: String
  ) throws -> VoiceFormattedDocument? {
    guard let json else {
      return nil
    }
    do {
      let document = try JSONDecoder().decode(
        VoiceFormattedDocument.self,
        from: Data(json.utf8)
      )
      guard
        try VoiceFormattedTextRenderer().render(
          document,
          supportsMultiline: true
        ) == expectedText
      else {
        throw VoiceFormattingError.invalidBlock
      }
      return document
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid result formatting."
      )
    }
  }

  static func encodedHistoryFormattedDocument(
    _ result: VoiceHistoryResult
  ) throws -> String? {
    guard let document = result.formattedDocument else {
      return nil
    }
    do {
      guard
        try VoiceFormattedTextRenderer().render(
          document,
          supportsMultiline: true
        ) == result.text
      else {
        throw VoiceFormattingError.invalidBlock
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return String(decoding: try encoder.encode(document), as: UTF8.self)
    } catch {
      throw VoiceSessionHistoryError.invalidResult(
        "A Formatted History result contains invalid structured evidence."
      )
    }
  }

  static func timedSpans(
    from json: String?
  ) throws -> [VoiceHistoryTimedSpan] {
    guard let json else {
      return []
    }
    do {
      return try JSONDecoder().decode(
        [VoiceHistoryTimedSpan].self,
        from: Data(json.utf8)
      )
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid timed transcript spans."
      )
    }
  }

  static func encodedTimedSpans(
    _ spans: [VoiceHistoryTimedSpan]
  ) throws -> String? {
    guard !spans.isEmpty else {
      return nil
    }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return String(decoding: try encoder.encode(spans), as: UTF8.self)
    } catch {
      throw VoiceSessionHistoryError.invalidResult(
        "History could not store timed transcript spans."
      )
    }
  }

  static func deliveryFailureReason(
    from rawValue: String?
  ) throws -> VoiceSessionDeliveryFailureReason? {
    guard let rawValue else {
      return nil
    }
    guard
      let reason = VoiceSessionDeliveryFailureReason(
        rawValue: rawValue
      )
    else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains an invalid delivery failure reason."
      )
    }
    return reason
  }

  static func validateDeliveryEvidence(
    _ document: VoiceSessionDocument
  ) throws {
    guard document.deliveryFailureReason != nil else {
      return
    }
    guard
      document.deliveryOutcome == .failed,
      document.deliveryFailure != nil,
      document.deliveredText.isEmpty
    else {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains contradictory delivery evidence."
      )
    }
  }

  static func formattedDocument(
    from json: String?,
    expectedRawText: String,
    expectedFormattedText: String
  ) throws -> VoiceFormattedDocument? {
    guard let json else {
      return nil
    }
    do {
      let document = try JSONDecoder().decode(
        VoiceFormattedDocument.self,
        from: Data(json.utf8)
      )
      guard document.rawText == expectedRawText else {
        throw VoiceFormattingError.invalidEvidenceReference
      }
      let rendered = try VoiceFormattedTextRenderer().render(
        document,
        supportsMultiline: true
      )
      guard rendered == expectedFormattedText else {
        throw VoiceFormattingError.invalidBlock
      }
      return document
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid structured formatting."
      )
    }
  }

  static func encodedFormattedDocument(
    _ document: VoiceFormattedDocument?,
    expectedRawText: String,
    expectedFormattedText: String
  ) throws -> String? {
    guard let document else {
      return nil
    }
    do {
      guard document.rawText == expectedRawText else {
        throw VoiceFormattingError.invalidEvidenceReference
      }
      let rendered = try VoiceFormattedTextRenderer().render(
        document,
        supportsMultiline: true
      )
      guard rendered == expectedFormattedText else {
        throw VoiceFormattingError.invalidBlock
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return String(decoding: try encoder.encode(document), as: UTF8.self)
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not store invalid structured formatting."
      )
    }
  }

  static func spokenEdits(
    from json: String?
  ) throws -> VoiceSpokenEditResult? {
    guard let json else {
      return nil
    }
    do {
      let result = try JSONDecoder().decode(
        VoiceSpokenEditResult.self,
        from: Data(json.utf8)
      )
      try VoiceSpokenEditReplayer().validate(result)
      return result
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid spoken-edit evidence."
      )
    }
  }

  static func encodedSpokenEdits(
    _ result: VoiceSpokenEditResult?
  ) throws -> String? {
    guard let result else {
      return nil
    }
    do {
      try VoiceSpokenEditReplayer().validate(result)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return String(decoding: try encoder.encode(result), as: UTF8.self)
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not store invalid spoken-edit evidence."
      )
    }
  }

  /// Rows written before decision 0060 have no engine column value; they used Apple.
  static func speechEngine(from json: String?) throws -> SpeechEngineUsage {
    guard let json else {
      return .apple
    }
    do {
      return try JSONDecoder().decode(SpeechEngineUsage.self, from: Data(json.utf8))
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History contains invalid speech engine evidence."
      )
    }
  }

  static func encodedSpeechEngine(_ usage: SpeechEngineUsage) throws -> String {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return String(decoding: try encoder.encode(usage), as: UTF8.self)
    } catch {
      throw VoiceSessionHistoryError.storageUnavailable(
        "Voice History could not store speech engine evidence."
      )
    }
  }
}
