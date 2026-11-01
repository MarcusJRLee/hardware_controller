#ifndef VOICE_FFI_BRIDGE_H
#define VOICE_FFI_BRIDGE_H

#include "../../../crates/voice_ffi/include/voice_ffi.h"

enum VoiceFFIBridgeStatusV1 {
  VoiceFFIBridgeStatusOK = VOICE_STATUS_OK,
  VoiceFFIBridgeStatusNullPointer = VOICE_STATUS_NULL_POINTER,
  VoiceFFIBridgeStatusInvalidArgument = VOICE_STATUS_INVALID_ARGUMENT,
  VoiceFFIBridgeStatusBufferTooSmall = VOICE_STATUS_BUFFER_TOO_SMALL,
  VoiceFFIBridgeStatusInternalFailure = VOICE_STATUS_INTERNAL_FAILURE,
  VoiceFFIBridgeStatusInvalidAgeLimit = VOICE_STATUS_INVALID_AGE_LIMIT,
  VoiceFFIBridgeStatusInvalidArtifactLimit =
      VOICE_STATUS_INVALID_ARTIFACT_LIMIT,
  VoiceFFIBridgeStatusInvalidByteLimit = VOICE_STATUS_INVALID_BYTE_LIMIT,
  VoiceFFIBridgeStatusInvalidReclaimRequest =
      VOICE_STATUS_INVALID_RECLAIM_REQUEST,
  VoiceFFIBridgeStatusInvalidArtifactSize = VOICE_STATUS_INVALID_ARTIFACT_SIZE,
  VoiceFFIBridgeStatusInvalidSessionId = VOICE_STATUS_INVALID_SESSION_ID,
  VoiceFFIBridgeStatusDuplicateSessionId = VOICE_STATUS_DUPLICATE_SESSION_ID,
  VoiceFFIBridgeStatusInvalidTimestamp = VOICE_STATUS_INVALID_TIMESTAMP,
  VoiceFFIBridgeStatusTooManyCandidates = VOICE_STATUS_TOO_MANY_CANDIDATES,
  VoiceFFIBridgeStatusInvalidUtf8Path = VOICE_STATUS_INVALID_UTF8_PATH,
  VoiceFFIBridgeStatusInvalidModelPackageRoot =
      VOICE_STATUS_INVALID_MODEL_PACKAGE_ROOT,
  VoiceFFIBridgeStatusInvalidModelPackageManifest =
      VOICE_STATUS_INVALID_MODEL_PACKAGE_MANIFEST,
  VoiceFFIBridgeStatusModelPackageLimitExceeded =
      VOICE_STATUS_MODEL_PACKAGE_LIMIT_EXCEEDED,
  VoiceFFIBridgeStatusModelPackageInventoryInvalid =
      VOICE_STATUS_MODEL_PACKAGE_INVENTORY_INVALID,
  VoiceFFIBridgeStatusModelPackageDigestMismatch =
      VOICE_STATUS_MODEL_PACKAGE_DIGEST_MISMATCH,
  VoiceFFIBridgeStatusModelPackageIoFailure =
      VOICE_STATUS_MODEL_PACKAGE_IO_FAILURE,
  VoiceFFIBridgeStatusInvalidHistoryArchiveRoot =
      VOICE_STATUS_INVALID_HISTORY_ARCHIVE_ROOT,
  VoiceFFIBridgeStatusInvalidHistoryArchiveManifest =
      VOICE_STATUS_INVALID_HISTORY_ARCHIVE_MANIFEST,
  VoiceFFIBridgeStatusHistoryArchiveLimitExceeded =
      VOICE_STATUS_HISTORY_ARCHIVE_LIMIT_EXCEEDED,
  VoiceFFIBridgeStatusHistoryArchiveInventoryInvalid =
      VOICE_STATUS_HISTORY_ARCHIVE_INVENTORY_INVALID,
  VoiceFFIBridgeStatusHistoryArchiveIntegrityMismatch =
      VOICE_STATUS_HISTORY_ARCHIVE_INTEGRITY_MISMATCH,
  VoiceFFIBridgeStatusHistoryArchiveIdentityInvalid =
      VOICE_STATUS_HISTORY_ARCHIVE_IDENTITY_INVALID,
  VoiceFFIBridgeStatusHistoryArchiveIoFailure =
      VOICE_STATUS_HISTORY_ARCHIVE_IO_FAILURE,
  VoiceFFIBridgeStatusASRRuntimeUnsupported =
      VOICE_STATUS_ASR_RUNTIME_UNSUPPORTED,
  VoiceFFIBridgeStatusASRCapabilityUnsupported =
      VOICE_STATUS_ASR_CAPABILITY_UNSUPPORTED,
  VoiceFFIBridgeStatusASRModelAmbiguous = VOICE_STATUS_ASR_MODEL_AMBIGUOUS,
};

enum VoiceFFIBridgeExpirationReasonV1 {
  VoiceFFIBridgeExpirationAgeLimit = VOICE_EXPIRATION_AGE_LIMIT,
  VoiceFFIBridgeExpirationArtifactLimit = VOICE_EXPIRATION_ARTIFACT_LIMIT,
  VoiceFFIBridgeExpirationByteLimit = VOICE_EXPIRATION_BYTE_LIMIT,
  VoiceFFIBridgeExpirationLowDisk = VOICE_EXPIRATION_LOW_DISK,
  VoiceFFIBridgeExpirationRecoveryLimit = VOICE_EXPIRATION_RECOVERY_LIMIT,
};

enum VoiceFFIBridgeModelRuntimeV1 {
  VoiceFFIBridgeModelRuntimeSherpaOnnx = VOICE_MODEL_RUNTIME_SHERPA_ONNX,
  VoiceFFIBridgeModelRuntimeWhisperCpp = VOICE_MODEL_RUNTIME_WHISPER_CPP,
  VoiceFFIBridgeModelRuntimeMistralRs = VOICE_MODEL_RUNTIME_MISTRAL_RS,
  VoiceFFIBridgeModelRuntimeLlamaCpp = VOICE_MODEL_RUNTIME_LLAMA_CPP,
};

enum VoiceFFIBridgeModelStageV1 {
  VoiceFFIBridgeModelStageAsr = VOICE_MODEL_STAGE_ASR,
  VoiceFFIBridgeModelStageFormatting = VOICE_MODEL_STAGE_FORMATTING,
  VoiceFFIBridgeModelStageVad = VOICE_MODEL_STAGE_VAD,
};

enum VoiceFFIBridgeModelCapabilityV1 {
  VoiceFFIBridgeModelCapabilityStreamingAsr =
      VOICE_MODEL_CAPABILITY_STREAMING_ASR,
  VoiceFFIBridgeModelCapabilityFileAsr = VOICE_MODEL_CAPABILITY_FILE_ASR,
  VoiceFFIBridgeModelCapabilityFormatting = VOICE_MODEL_CAPABILITY_FORMATTING,
  VoiceFFIBridgeModelCapabilityVad = VOICE_MODEL_CAPABILITY_VAD,
};

#endif
