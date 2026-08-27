import Foundation
import Security

public struct VoiceInputKeychainStore: VoiceInputStateStoring, Sendable {
  public static let defaultMaximumRecordByteCount = 64 * 1_024

  private let service: String
  private let maximumRecordByteCount: Int

  public init(
    service: String = "com.longdevity.hardwarecontroller.voiceinput.handoff",
    maximumRecordByteCount: Int = Self.defaultMaximumRecordByteCount
  ) {
    self.service = service
    self.maximumRecordByteCount = maximumRecordByteCount
  }

  public func readSnapshot() throws -> VoiceInputSnapshot {
    guard let data = try readData(account: Account.snapshot.rawValue) else {
      return .idle(sequence: 0)
    }
    guard let snapshot = try? VoiceInputJSON.decoder.decode(VoiceInputSnapshot.self, from: data)
    else {
      throw VoiceInputStoreError.invalidSnapshot
    }
    return snapshot
  }

  public func writeSnapshot(_ snapshot: VoiceInputSnapshot) throws {
    let data = try VoiceInputJSON.encoder.encode(snapshot)
    try validate(data)
    try replace(
      data: data,
      account: Account.snapshot.rawValue
    )
  }

  public func readCommand() throws -> VoiceInputCommand? {
    guard let data = try readData(account: Account.command.rawValue) else {
      return nil
    }
    guard let command = try? VoiceInputJSON.decoder.decode(VoiceInputCommand.self, from: data)
    else {
      throw VoiceInputStoreError.invalidCommand
    }
    return command
  }

  public func writeCommand(_ command: VoiceInputCommand) throws {
    let data = try VoiceInputJSON.encoder.encode(command)
    try validate(data)
    let status = SecItemAdd(addQuery(data: data, account: Account.command.rawValue), nil)
    if status == errSecDuplicateItem {
      throw VoiceInputStoreError.commandPending
    }
    try check(status)
  }

  public func consumeCommand() throws -> VoiceInputCommand? {
    guard let command = try readCommand() else {
      return nil
    }
    let status = SecItemDelete(baseQuery(account: Account.command.rawValue))
    if status != errSecItemNotFound {
      try check(status)
    }
    return command
  }

  public func readKeyboardObservedAt() throws -> Date? {
    guard let data = try readData(account: Account.keyboardPresence.rawValue) else {
      return nil
    }
    guard
      let presence = try? VoiceInputJSON.decoder.decode(
        KeyboardPresence.self,
        from: data
      ),
      presence.schemaRevision == KeyboardPresence.schemaRevision
    else {
      throw VoiceInputStoreError.invalidKeyboardPresence
    }
    return presence.observedAt
  }

  public func markKeyboardObserved(at observedAt: Date) throws {
    let data = try VoiceInputJSON.encoder.encode(
      KeyboardPresence(
        schemaRevision: KeyboardPresence.schemaRevision,
        observedAt: observedAt
      )
    )
    try validate(data)
    try replace(data: data, account: Account.keyboardPresence.rawValue)
  }

  public func removeAll() throws {
    for account in [
      Account.snapshot.rawValue,
      Account.command.rawValue,
      Account.keyboardPresence.rawValue,
    ] {
      let status = SecItemDelete(baseQuery(account: account))
      if status != errSecItemNotFound {
        try check(status)
      }
    }
  }

  private func readData(account: String) throws -> Data? {
    var query = baseQueryDictionary(account: account)
    query[kSecMatchLimit] = kSecMatchLimitOne
    query[kSecReturnData] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return nil
    }
    try check(status)
    guard let data = item as? Data else {
      throw VoiceInputStoreError.keychain(status: errSecInternalError)
    }
    try validate(data)
    return data
  }

  private func validate(_ data: Data) throws {
    guard data.count <= maximumRecordByteCount else {
      throw VoiceInputStoreError.recordTooLarge(limit: maximumRecordByteCount)
    }
  }

  private func replace(data: Data, account: String) throws {
    let update = [kSecValueData: data] as CFDictionary
    let status = SecItemUpdate(baseQuery(account: account), update)
    if status != errSecItemNotFound {
      try check(status)
      return
    }

    let addStatus = SecItemAdd(addQuery(data: data, account: account), nil)
    if addStatus == errSecDuplicateItem {
      try check(SecItemUpdate(baseQuery(account: account), update))
    } else {
      try check(addStatus)
    }
  }

  private func addQuery(data: Data, account: String) -> CFDictionary {
    var query = baseQueryDictionary(account: account)
    query[kSecValueData] = data
    query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return query as CFDictionary
  }

  private func baseQuery(account: String) -> CFDictionary {
    baseQueryDictionary(account: account) as CFDictionary
  }

  private func baseQueryDictionary(account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrSynchronizable: false,
    ]
  }

  private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
      throw VoiceInputStoreError.keychain(status: status)
    }
  }

  private enum Account: String {
    case snapshot
    case command
    case keyboardPresence = "keyboard_presence"
  }

  private struct KeyboardPresence: Codable, Sendable {
    static let schemaRevision = 1

    let schemaRevision: Int
    let observedAt: Date
  }
}
