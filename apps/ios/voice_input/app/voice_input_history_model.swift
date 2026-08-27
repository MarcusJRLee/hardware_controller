import Combine
import Foundation

protocol VoiceInputHistoryAccessing: Sendable {
  func recent(limit: Int) async throws -> [VoiceInputHistorySession]
  func search(
    query: String,
    limit: Int
  ) async throws -> [VoiceInputHistorySession]
  func enforceRetention(now: Date) async throws
}

extension VoiceInputHistoryRepository: VoiceInputHistoryAccessing {}

@MainActor
final class VoiceInputHistoryModel: ObservableObject {
  @Published private(set) var sessions: [VoiceInputHistorySession] = []
  @Published var query = ""
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?

  private let history: (any VoiceInputHistoryAccessing)?
  private let initializationError: String?
  private let resultLimit: Int

  init(
    history: (any VoiceInputHistoryAccessing)?,
    initializationError: String? = nil,
    resultLimit: Int = 100
  ) {
    self.history = history
    self.initializationError = initializationError
    self.resultLimit = resultLimit
  }

  func refresh() async {
    await load(searching: false)
  }

  func search() async {
    await load(searching: true)
  }

  private func load(searching: Bool) async {
    guard let history else {
      sessions = []
      errorMessage = initializationError ?? "Local Voice History is unavailable."
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      try await history.enforceRetention(now: .now)
      sessions =
        searching
        ? try await history.search(query: query, limit: resultLimit)
        : try await history.recent(limit: resultLimit)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
