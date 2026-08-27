import Foundation
import VoiceWhisperBridge
import XCTest

@testable import VoiceInput

final class VoiceInputWhisperTranscriberTest: XCTestCase {
  func testRuntimeSegmentsDecodeToTimedRawTranscript() throws {
    let text = Data(" first  second ".utf8)
    let segments = [
      VoiceWhisperSegmentV1(
        start_milliseconds: 0,
        end_milliseconds: 500,
        text_offset: 0,
        text_length: 7
      ),
      VoiceWhisperSegmentV1(
        start_milliseconds: 500,
        end_milliseconds: 1_200,
        text_offset: 7,
        text_length: 8
      ),
    ]
    let model = makeInstalledASRPackage()

    let result = try VoiceInputWhisperTranscriber.decode(
      transcript: text[...],
      runtimeSegments: segments[...],
      model: model
    )

    XCTAssertEqual(result.text, "first second")
    XCTAssertEqual(
      result.segments,
      [
        VoiceInputTranscriptSegment(
          startMilliseconds: 0,
          endMilliseconds: 500,
          text: "first"
        ),
        VoiceInputTranscriptSegment(
          startMilliseconds: 500,
          endMilliseconds: 1_200,
          text: "second"
        ),
      ]
    )
  }

  func testOutOfBoundsOrBackwardSegmentFailsClosed() {
    let model = makeInstalledASRPackage()
    let invalid = VoiceWhisperSegmentV1(
      start_milliseconds: 100,
      end_milliseconds: 0,
      text_offset: 0,
      text_length: 100
    )

    XCTAssertThrowsError(
      try VoiceInputWhisperTranscriber.decode(
        transcript: Data("short".utf8)[...],
        runtimeSegments: [invalid][...],
        model: model
      )
    ) { error in
      XCTAssertEqual(error as? VoiceInputTranscriptionError, .invalidRuntimeResult)
    }
  }

  func testInvalidUTF8OrNoncontiguousSegmentsFailClosed() {
    let model = makeInstalledASRPackage()
    let segment = VoiceWhisperSegmentV1(
      start_milliseconds: 0,
      end_milliseconds: 100,
      text_offset: 0,
      text_length: 1
    )
    XCTAssertThrowsError(
      try VoiceInputWhisperTranscriber.decode(
        transcript: Data([0xFF])[...],
        runtimeSegments: [segment][...],
        model: model
      )
    ) { error in
      XCTAssertEqual(error as? VoiceInputTranscriptionError, .invalidRuntimeResult)
    }

    let skippedByte = VoiceWhisperSegmentV1(
      start_milliseconds: 0,
      end_milliseconds: 100,
      text_offset: 1,
      text_length: 1
    )
    XCTAssertThrowsError(
      try VoiceInputWhisperTranscriber.decode(
        transcript: Data("ab".utf8)[...],
        runtimeSegments: [skippedByte][...],
        model: model
      )
    ) { error in
      XCTAssertEqual(error as? VoiceInputTranscriptionError, .invalidRuntimeResult)
    }
  }

  func testRuntimeLanguageUsesOnePackageLanguageOrAutomaticDetection() {
    XCTAssertEqual(
      VoiceInputWhisperTranscriber.runtimeLanguage(for: ["en-US"]),
      "en"
    )
    XCTAssertEqual(
      VoiceInputWhisperTranscriber.runtimeLanguage(for: ["en-US", "fr-FR"]),
      "auto"
    )
    XCTAssertEqual(
      VoiceInputWhisperTranscriber.runtimeLanguage(for: ["invalid_primary-US"]),
      "auto"
    )
  }
}
