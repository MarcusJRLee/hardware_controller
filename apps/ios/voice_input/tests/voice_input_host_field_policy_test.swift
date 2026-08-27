import UIKit
import XCTest

@testable import VoiceInputShared

final class VoiceInputHostFieldPolicyTest: XCTestCase {
  func testOnlyGeneralTextIsEligibleForVoiceDelivery() {
    let policy = VoiceInputHostFieldPolicy()

    XCTAssertEqual(policy.eligibility(for: .generalText), .supported)
    for kind in VoiceInputHostFieldKind.allCases where kind != .generalText {
      XCTAssertEqual(policy.eligibility(for: kind), .unsupported)
    }
  }

  func testUIKitMapperRejectsSensitiveAndConstrainedTraits() {
    let mapper = VoiceInputUIKitFieldMapper()

    for keyboardType in [
      UIKeyboardType.phonePad,
      .namePhonePad,
    ] {
      XCTAssertEqual(
        mapper.kind(keyboardType: keyboardType, textContentType: nil),
        .phone
      )
    }
    for keyboardType in [
      UIKeyboardType.numberPad,
      .decimalPad,
      .asciiCapableNumberPad,
    ] {
      XCTAssertEqual(
        mapper.kind(keyboardType: keyboardType, textContentType: nil),
        .numeric
      )
    }
    assertContentTypes([.username, .password, .newPassword], mapTo: .credential)
    assertContentTypes([.oneTimeCode], mapTo: .oneTimeCode)
    assertContentTypes([.telephoneNumber], mapTo: .phone)
    assertContentTypes(
      [
        .creditCardNumber,
        .creditCardExpiration,
        .creditCardExpirationMonth,
        .creditCardExpirationYear,
        .creditCardSecurityCode,
        .creditCardType,
        .creditCardName,
        .creditCardGivenName,
        .creditCardMiddleName,
        .creditCardFamilyName,
      ],
      mapTo: .payment
    )
    assertContentTypes(
      [
        .birthdate,
        .birthdateDay,
        .birthdateMonth,
        .birthdateYear,
        .cellularEID,
        .cellularIMEI,
      ],
      mapTo: .sensitiveIdentifier
    )
    XCTAssertEqual(
      mapper.kind(
        keyboardType: .default,
        textContentType: UITextContentType(rawValue: "com.example.private-field")
      ),
      .unverified
    )
  }

  func testUIKitMapperAllowsKnownGeneralTextTraits() {
    let mapper = VoiceInputUIKitFieldMapper()

    for keyboardType in [
      UIKeyboardType.default,
      .asciiCapable,
      .numbersAndPunctuation,
      .URL,
      .emailAddress,
      .twitter,
      .webSearch,
    ] {
      XCTAssertEqual(
        mapper.kind(keyboardType: keyboardType, textContentType: nil),
        .generalText
      )
    }
    assertContentTypes(
      [
        .name,
        .namePrefix,
        .givenName,
        .middleName,
        .familyName,
        .nameSuffix,
        .nickname,
        .organizationName,
        .jobTitle,
        .location,
        .fullStreetAddress,
        .streetAddressLine1,
        .streetAddressLine2,
        .addressCity,
        .addressState,
        .addressCityAndState,
        .sublocality,
        .countryName,
        .postalCode,
        .emailAddress,
        .URL,
        .dateTime,
        .flightNumber,
        .shipmentTrackingNumber,
      ],
      mapTo: .generalText
    )
  }

  func testUIKitMapperRejectsMissingAndUnknownKeyboardTypes() {
    let mapper = VoiceInputUIKitFieldMapper()

    XCTAssertEqual(
      mapper.kind(keyboardType: nil, textContentType: nil),
      .unverified
    )
    XCTAssertEqual(
      mapper.kind(keyboardType: UIKeyboardType(rawValue: 1_000), textContentType: nil),
      .unverified
    )
  }

  private func assertContentTypes(
    _ contentTypes: [UITextContentType],
    mapTo expectedKind: VoiceInputHostFieldKind,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let mapper = VoiceInputUIKitFieldMapper()
    for contentType in contentTypes {
      XCTAssertEqual(
        mapper.kind(keyboardType: .default, textContentType: contentType),
        expectedKind,
        contentType.rawValue,
        file: file,
        line: line
      )
    }
  }
}
