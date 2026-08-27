import Foundation
import Security

public struct VoiceProbeKeychainStore: VoiceProbeStateStoring, Sendable {
  public static let defaultMaximumRecordByteCount = 64 * 1_024

  private let service: String
  private let maximumRecordByteCount: Int

  public init(
    service: String = "com.longdevity.hardwarecontroller.voiceprobe.handoff",
    maximumRecordByteCount: Int = Self.defaultMaximumRecordByteCount
  ) {
    self.service = service
    self.maximumRecordByteCount = maximumRecordByteCount
  }

  public func readSnapshot() throws -> VoiceProbeSnapshot {
    guard let data = try readData(account: Account.snapshot.rawValue) else {
      return .idle(sequence: 0)
    }
    guard let snapshot = try? VoiceProbeJSON.decoder.decode(VoiceProbeSnapshot.self, from: data)
    else {
      throw VoiceProbeStoreError.invalidSnapshot
    }
    return snapshot
  }

  public func writeSnapshot(_ snapshot: VoiceProbeSnapshot) throws {
    let data = try VoiceProbeJSON.encoder.encode(snapshot)
    try validate(data)
    try replace(
      data: data,
      account: Account.snapshot.rawValue
    )
  }

  public func readCommand() throws -> VoiceProbeCommand? {
    guard let data = try readData(account: Account.command.rawValue) else {
      return nil
    }
    guard let command = try? VoiceProbeJSON.decoder.decode(VoiceProbeCommand.self, from: data)
    else {
      throw VoiceProbeStoreError.invalidCommand
    }
    return command
  }

  public func writeCommand(_ command: VoiceProbeCommand) throws {
    let data = try VoiceProbeJSON.encoder.encode(command)
    try validate(data)
    let status = SecItemAdd(addQuery(data: data, account: Account.command.rawValue), nil)
    if status == errSecDuplicateItem {
      throw VoiceProbeStoreError.commandPending
    }
    try check(status)
  }

  public func consumeCommand() throws -> VoiceProbeCommand? {
    guard let command = try readCommand() else {
      return nil
    }
    let status = SecItemDelete(baseQuery(account: Account.command.rawValue))
    if status != errSecItemNotFound {
      try check(status)
    }
    return command
  }

  public func removeAll() throws {
    for account in [Account.snapshot.rawValue, Account.command.rawValue] {
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
      throw VoiceProbeStoreError.keychain(status: errSecInternalError)
    }
    try validate(data)
    return data
  }

  private func validate(_ data: Data) throws {
    guard data.count <= maximumRecordByteCount else {
      throw VoiceProbeStoreError.recordTooLarge(limit: maximumRecordByteCount)
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
      throw VoiceProbeStoreError.keychain(status: status)
    }
  }

  private enum Account: String {
    case snapshot
    case command
  }
}
