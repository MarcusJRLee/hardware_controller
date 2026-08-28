import Foundation
import UIKit
import UniformTypeIdentifiers

public struct VoiceInputLocalCopyPayload: Equatable, Sendable {
  public let text: String
  public let expiresAt: Date

  public init(text: String, expiresAt: Date) {
    self.text = text
    self.expiresAt = expiresAt
  }
}

public enum VoiceInputLocalCopyError: Error, Equatable, Sendable {
  case invalidConfiguration
  case emptyText
  case textTooLarge(limit: Int)
}

public struct VoiceInputLocalCopyPolicy: Equatable, Sendable {
  public static let defaultMaximumUTF8ByteCount = 256 * 1_024
  public static let defaultLifetime: TimeInterval = 10 * 60

  public let maximumUTF8ByteCount: Int
  public let lifetime: TimeInterval

  public init(
    maximumUTF8ByteCount: Int = Self.defaultMaximumUTF8ByteCount,
    lifetime: TimeInterval = Self.defaultLifetime
  ) {
    self.maximumUTF8ByteCount = maximumUTF8ByteCount
    self.lifetime = lifetime
  }

  public func payload(text: String, now: Date) throws -> VoiceInputLocalCopyPayload {
    guard maximumUTF8ByteCount > 0, lifetime > 0, lifetime.isFinite else {
      throw VoiceInputLocalCopyError.invalidConfiguration
    }
    guard !text.isEmpty else {
      throw VoiceInputLocalCopyError.emptyText
    }
    guard text.utf8.count <= maximumUTF8ByteCount else {
      throw VoiceInputLocalCopyError.textTooLarge(limit: maximumUTF8ByteCount)
    }
    return VoiceInputLocalCopyPayload(
      text: text,
      expiresAt: now.addingTimeInterval(lifetime)
    )
  }
}

@MainActor
public struct VoiceInputSystemLocalClipboard {
  private let policy: VoiceInputLocalCopyPolicy

  public init(policy: VoiceInputLocalCopyPolicy = VoiceInputLocalCopyPolicy()) {
    self.policy = policy
  }

  @discardableResult
  public func copy(
    _ text: String,
    now: Date = .now
  ) throws -> VoiceInputLocalCopyPayload {
    let payload = try policy.payload(text: text, now: now)
    UIPasteboard.general.setItems(
      [[UTType.plainText.identifier: payload.text]],
      options: [
        .localOnly: true,
        .expirationDate: payload.expiresAt,
      ]
    )
    return payload
  }
}
