import UIKit

public enum VoiceInputHostFieldKind:
  String,
  CaseIterable,
  Equatable,
  Sendable
{
  case generalText
  case phone
  case numeric
  case credential
  case oneTimeCode
  case payment
  case sensitiveIdentifier
  case unverified
}

public enum VoiceInputFieldEligibility: Equatable, Sendable {
  case supported
  case unsupported
}

public struct VoiceInputHostFieldPolicy: Equatable, Sendable {
  public init() {}

  public func eligibility(
    for kind: VoiceInputHostFieldKind
  ) -> VoiceInputFieldEligibility {
    kind == .generalText ? .supported : .unsupported
  }
}

public struct VoiceInputUIKitFieldMapper: Equatable, Sendable {
  public init() {}

  public func kind(
    keyboardType: UIKeyboardType?,
    textContentType: UITextContentType?
  ) -> VoiceInputHostFieldKind {
    guard let keyboardType else {
      return .unverified
    }
    switch keyboardType {
    case .phonePad, .namePhonePad:
      return .phone
    case .numberPad, .decimalPad, .asciiCapableNumberPad:
      return .numeric
    case .default, .asciiCapable, .numbersAndPunctuation, .URL, .emailAddress,
      .twitter, .webSearch:
      break
    @unknown default:
      return .unverified
    }

    guard let textContentType else {
      return .generalText
    }
    if Self.generalTextContentTypes.contains(textContentType) {
      return .generalText
    }
    if Self.credentialContentTypes.contains(textContentType) {
      return .credential
    }
    if textContentType == .oneTimeCode {
      return .oneTimeCode
    }
    if textContentType == .telephoneNumber {
      return .phone
    }
    if Self.paymentContentTypes.contains(textContentType) {
      return .payment
    }
    if Self.sensitiveIdentifierContentTypes.contains(textContentType) {
      return .sensitiveIdentifier
    }
    return .unverified
  }

  private static let generalTextContentTypes: Set<UITextContentType> = [
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
  ]

  private static let credentialContentTypes: Set<UITextContentType> = [
    .username,
    .password,
    .newPassword,
  ]

  private static let paymentContentTypes: Set<UITextContentType> = [
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
  ]

  private static let sensitiveIdentifierContentTypes: Set<UITextContentType> = [
    .birthdate,
    .birthdateDay,
    .birthdateMonth,
    .birthdateYear,
    .cellularEID,
    .cellularIMEI,
  ]
}
