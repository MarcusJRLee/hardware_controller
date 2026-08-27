import Foundation
import Testing

@testable import HardwareControllerCore

struct VoiceHistoryRetentionPlannerTest {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test
  func portableFixtureMatchesSwiftPolicy() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "cuj/voice_retention_v1.json")
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let fixture = try decoder.decode(
      RetentionFixture.self,
      from: Data(contentsOf: fixtureURL)
    )
    #expect(fixture.revision == 1)

    for fixtureCase in fixture.cases {
      let candidates = try fixtureCase.candidates.map { candidate in
        let identifier = try #require(UUID(uuidString: candidate.id))
        return VoiceHistoryRetentionCandidate(
          id: identifier,
          endedAt: date(candidate.endedAtUnixMilliseconds),
          audioBytes: candidate.audioBytes,
          isPinned: candidate.isPinned,
          isActive: candidate.isActive,
          isSoleRecoveryArtifact: candidate.isSoleRecoveryArtifact,
          recoveryExpiresAt: candidate.recoveryExpiresAtUnixMilliseconds.map(
            date
          )
        )
      }
      let plan = try VoiceHistoryRetentionPlanner.plan(
        candidates: candidates,
        settings: VoiceHistoryRetentionSettings(
          maximumAgeDays: fixtureCase.settings.maximumAgeDays,
          maximumAudioBytes: fixtureCase.settings.maximumAudioBytes,
          maximumArtifactCount: fixtureCase.settings.maximumArtifactCount
        ),
        now: date(fixtureCase.nowUnixMilliseconds),
        lowDiskReclaimBytes: fixtureCase.lowDiskReclaimBytes
      )
      let expectedDecisions = try fixtureCase.expected.decisions.map {
        decision in
        VoiceHistoryRetentionDecision(
          sessionID: try #require(UUID(uuidString: decision.sessionId)),
          reason: decision.reason,
          audioBytes: decision.audioBytes
        )
      }
      let expected = fixtureCase.expected

      #expect(plan.decisions == expectedDecisions, "\(fixtureCase.name)")
      #expect(plan.reclaimedBytes == expected.reclaimedBytes)
      #expect(plan.lowDiskShortfallBytes == expected.lowDiskShortfallBytes)
      #expect(plan.remainingAudioBytes == expected.remainingAudioBytes)
      #expect(
        plan.remainingArtifactCount == expected.remainingArtifactCount
      )
      #expect(plan.exceedsByteLimit == expected.exceedsByteLimit)
      #expect(plan.exceedsArtifactLimit == expected.exceedsArtifactLimit)
    }
  }

  @Test
  func defaultsAreExplicitAndValidated() throws {
    let settings = try VoiceHistoryRetentionSettings.macOSDefault.validated()

    #expect(settings.maximumAgeDays == 90)
    #expect(
      settings.maximumAudioBytes == Int64(2) * 1_024 * 1_024 * 1_024
    )
    #expect(settings.maximumArtifactCount == 5_000)
    #expect(
      VoiceHistoryRetentionSettings.iOSDefault.maximumAudioBytes
        == Int64(1) * 1_024 * 1_024 * 1_024
    )
    #expect(
      VoiceHistoryRetentionSettings.iOSDefault.maximumArtifactCount == 2_000
    )
  }

  @Test
  func ageLimitExpiresOldestEligibleAndPreservesProtectedAudio() throws {
    let old = candidate(id: 1, daysAgo: 91)
    let pinned = candidate(id: 2, daysAgo: 100, isPinned: true)
    let active = candidate(id: 3, daysAgo: 100, isActive: true)
    let recovery = candidate(id: 4, daysAgo: 100, isRecovery: true)
    let exactCutoff = candidate(id: 5, daysAgo: 90)

    let plan = try VoiceHistoryRetentionPlanner.plan(
      candidates: [exactCutoff, recovery, active, pinned, old],
      settings: settings(ageDays: 90),
      now: now
    )

    #expect(plan.decisions == [decision(old, reason: .ageLimit)])
  }

  @Test
  func artifactLimitUsesEndTimeThenIdentifierForStableOrdering() throws {
    let later = candidate(id: 3, daysAgo: 1)
    let tiedSecond = candidate(id: 2, daysAgo: 2)
    let tiedFirst = candidate(id: 1, daysAgo: 2)

    let plan = try VoiceHistoryRetentionPlanner.plan(
      candidates: [later, tiedSecond, tiedFirst],
      settings: settings(artifactCount: 1),
      now: now
    )

    #expect(
      plan.decisions == [
        decision(tiedFirst, reason: .artifactLimit),
        decision(tiedSecond, reason: .artifactLimit),
      ]
    )
    #expect(plan.remainingArtifactCount == 1)
  }

  @Test
  func byteLimitReclaimsToNinetyPercentLowWater() throws {
    let candidates = (1...11).map {
      candidate(id: $0, daysAgo: 12 - $0, bytes: 10)
    }

    let plan = try VoiceHistoryRetentionPlanner.plan(
      candidates: candidates,
      settings: settings(bytes: 100),
      now: now
    )

    #expect(plan.decisions.count == 2)
    #expect(plan.reclaimedBytes == 20)
    #expect(plan.remainingAudioBytes == 90)
    #expect(!plan.exceedsByteLimit)
  }

  @Test
  func zeroLimitsRemoveAllEligibleAudioButRetainProtectedAudio() throws {
    let eligible = candidate(id: 1, daysAgo: 1, bytes: 10)
    let pinned = candidate(id: 2, daysAgo: 2, bytes: 20, isPinned: true)

    let plan = try VoiceHistoryRetentionPlanner.plan(
      candidates: [eligible, pinned],
      settings: settings(ageDays: 0, bytes: 0, artifactCount: 0),
      now: now
    )

    #expect(plan.decisions == [decision(eligible, reason: .ageLimit)])
    #expect(plan.remainingAudioBytes == 20)
    #expect(plan.exceedsByteLimit)
    #expect(plan.exceedsArtifactLimit)
  }

  @Test
  func zeroAgeExpiresAudioEndingAtTheEnforcementInstant() throws {
    let justCompleted = candidate(id: 1, daysAgo: 0)

    let plan = try VoiceHistoryRetentionPlanner.plan(
      candidates: [justCompleted],
      settings: settings(ageDays: 0),
      now: now
    )

    #expect(
      plan.decisions == [decision(justCompleted, reason: .ageLimit)]
    )
  }

  @Test
  func lowDiskUsesSameOrderingAndReportsProtectedShortfall() throws {
    let oldest = candidate(id: 1, daysAgo: 3, bytes: 20)
    let pinned = candidate(id: 2, daysAgo: 2, bytes: 40, isPinned: true)
    let newest = candidate(id: 3, daysAgo: 1, bytes: 30)

    let plan = try VoiceHistoryRetentionPlanner.plan(
      candidates: [newest, pinned, oldest],
      settings: settings(),
      now: now,
      lowDiskReclaimBytes: 60
    )

    #expect(
      plan.decisions == [
        decision(oldest, reason: .lowDisk),
        decision(newest, reason: .lowDisk),
      ]
    )
    #expect(plan.reclaimedBytes == 50)
    #expect(plan.lowDiskShortfallBytes == 10)
  }

  @Test
  func quotaReclamationAlsoSatisfiesLowDiskRequest() throws {
    let oldest = candidate(id: 1, daysAgo: 3, bytes: 10)
    let middle = candidate(id: 2, daysAgo: 2, bytes: 10)
    let newest = candidate(id: 3, daysAgo: 1, bytes: 10)

    let plan = try VoiceHistoryRetentionPlanner.plan(
      candidates: [newest, middle, oldest],
      settings: settings(artifactCount: 2),
      now: now,
      lowDiskReclaimBytes: 10
    )

    #expect(plan.decisions == [decision(oldest, reason: .artifactLimit)])
    #expect(plan.lowDiskShortfallBytes == 0)
  }

  @Test
  func unlimitedSettingsDoNotExpireAudio() throws {
    let plan = try VoiceHistoryRetentionPlanner.plan(
      candidates: [candidate(id: 1, daysAgo: 1_000)],
      settings: settings(),
      now: now
    )

    #expect(plan.decisions.isEmpty)
    #expect(plan.remainingArtifactCount == 1)
  }

  @Test
  func recoveryAudioExpiresAfterItsDedicatedWindowUnlessPinned() throws {
    let expired = candidate(
      id: 1,
      daysAgo: 2,
      recoveryExpiresAt: now.addingTimeInterval(-1)
    )
    let pinned = candidate(
      id: 2,
      daysAgo: 2,
      isPinned: true,
      recoveryExpiresAt: now.addingTimeInterval(-1)
    )
    let retained = candidate(
      id: 3,
      daysAgo: 2,
      recoveryExpiresAt: now.addingTimeInterval(1)
    )

    let plan = try VoiceHistoryRetentionPlanner.plan(
      candidates: [retained, pinned, expired],
      settings: .unlimited,
      now: now
    )

    #expect(
      plan.decisions == [decision(expired, reason: .recoveryLimit)]
    )
  }

  @Test
  func invalidInputsAreRejected() {
    #expect(throws: VoiceHistoryRetentionValidationError.invalidAgeLimit) {
      try settings(ageDays: -1).validated()
    }
    #expect(throws: VoiceHistoryRetentionValidationError.invalidByteLimit) {
      try settings(bytes: -1).validated()
    }
    #expect(throws: VoiceHistoryRetentionValidationError.invalidArtifactLimit) {
      try settings(artifactCount: -1).validated()
    }
    #expect(throws: VoiceHistoryRetentionValidationError.invalidReclaimRequest) {
      try VoiceHistoryRetentionPlanner.plan(
        candidates: [],
        settings: settings(),
        now: now,
        lowDiskReclaimBytes: -1
      )
    }
    #expect(throws: VoiceHistoryRetentionValidationError.invalidArtifactSize) {
      try VoiceHistoryRetentionPlanner.plan(
        candidates: [candidate(id: 1, daysAgo: 1, bytes: -1)],
        settings: settings(),
        now: now
      )
    }
    #expect(throws: VoiceHistoryRetentionValidationError.invalidArtifactSize) {
      try VoiceHistoryRetentionPlanner.plan(
        candidates: [
          candidate(id: 1, daysAgo: 2, bytes: Int64.max),
          candidate(id: 2, daysAgo: 1, bytes: 1),
        ],
        settings: settings(),
        now: now
      )
    }
  }

  private func settings(
    ageDays: Int? = nil,
    bytes: Int64? = nil,
    artifactCount: Int? = nil
  ) -> VoiceHistoryRetentionSettings {
    VoiceHistoryRetentionSettings(
      maximumAgeDays: ageDays,
      maximumAudioBytes: bytes,
      maximumArtifactCount: artifactCount
    )
  }

  private func candidate(
    id: Int,
    daysAgo: Int,
    bytes: Int64 = 10,
    isPinned: Bool = false,
    isActive: Bool = false,
    isRecovery: Bool = false,
    recoveryExpiresAt: Date? = nil
  ) -> VoiceHistoryRetentionCandidate {
    guard
      let identifier = UUID(
        uuidString: String(
          format: "00000000-0000-0000-0000-%012d",
          id
        )
      )
    else {
      fatalError("The fixed test identifier must be valid.")
    }
    return VoiceHistoryRetentionCandidate(
      id: identifier,
      endedAt: now.addingTimeInterval(-TimeInterval(daysAgo) * 86_400),
      audioBytes: bytes,
      isPinned: isPinned,
      isActive: isActive,
      isSoleRecoveryArtifact: isRecovery,
      recoveryExpiresAt: recoveryExpiresAt
    )
  }

  private func decision(
    _ candidate: VoiceHistoryRetentionCandidate,
    reason: VoiceHistoryAudioExpirationReason
  ) -> VoiceHistoryRetentionDecision {
    VoiceHistoryRetentionDecision(
      sessionID: candidate.id,
      reason: reason,
      audioBytes: candidate.audioBytes
    )
  }

  private func date(_ unixMilliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(unixMilliseconds) / 1_000)
  }

  private struct RetentionFixture: Decodable {
    let revision: Int
    let cases: [RetentionFixtureCase]
  }

  private struct RetentionFixtureCase: Decodable {
    let name: String
    let nowUnixMilliseconds: Int64
    let settings: RetentionFixtureSettings
    let lowDiskReclaimBytes: Int64
    let candidates: [RetentionFixtureCandidate]
    let expected: RetentionFixturePlan
  }

  private struct RetentionFixtureSettings: Decodable {
    let maximumAgeDays: Int?
    let maximumAudioBytes: Int64?
    let maximumArtifactCount: Int?
  }

  private struct RetentionFixtureCandidate: Decodable {
    let id: String
    let endedAtUnixMilliseconds: Int64
    let audioBytes: Int64
    let isPinned: Bool
    let isActive: Bool
    let isSoleRecoveryArtifact: Bool
    let recoveryExpiresAtUnixMilliseconds: Int64?
  }

  private struct RetentionFixturePlan: Decodable {
    let decisions: [RetentionFixtureDecision]
    let reclaimedBytes: Int64
    let lowDiskShortfallBytes: Int64
    let remainingAudioBytes: Int64
    let remainingArtifactCount: Int
    let exceedsByteLimit: Bool
    let exceedsArtifactLimit: Bool
  }

  private struct RetentionFixtureDecision: Decodable {
    let sessionId: String
    let reason: VoiceHistoryAudioExpirationReason
    let audioBytes: Int64
  }
}
