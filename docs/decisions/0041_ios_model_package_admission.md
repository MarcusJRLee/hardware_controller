# 0041: Admit local Model packages in the iOS containing app

- **Status:** Accepted
- **Date:** 2026-08-27
- **Implements:** [0037](0037_portable_model_package_validation.md),
  [0039](0039_linked_apple_voice_adapter.md)

## Context

iOS needs local model management before production ASR can replace the Gate K0
handoff placeholder. Model bytes can be large and untrusted. The app must not
load them directly from a security-scoped Files location or duplicate the
portable admission policy in Swift.

## Decision matrix

| Criterion | Private staging plus Rust admission | Run from Files location | Swift-only admission |
| --- | ---: | ---: | ---: |
| Stable offline custody | 5 | 1 | 5 |
| Shared cross-platform policy | 5 | 5 | 1 |
| Link/path/inventory safety | 5 | 1 | 3 |
| Atomic identity handling | 5 | 1 | 4 |
| Runtime independence | 5 | 5 | 5 |
| **Total** | **25** | **13** | **18** |

## Decision

Build `voice_ffi` as optimized static archives for iOS device and simulator,
package them in an ignored XCFramework, and expose the existing typed Swift
adapter through the generated iOS project. The app invokes the actual Rust
Model-package validator; it does not ship a REST service or dynamic Rust
runtime.

The containing app accepts one user-selected folder under a security-scoped
access window. It independently bounds entries, payload files, manifest bytes,
and installed bytes; rejects links and unsupported entries; copies into a
private staging directory; then asks Rust to validate the canonical inventory,
metadata, exact sizes, and SHA-256 digests. Installation moves the validated
directory atomically into `package_id/version`. Identical installs are
idempotent; different bytes under one identity fail closed. Failed and stale
staging directories are removed.

The Model library independently caps total verified bytes and installed package
versions. Defaults are 12 GiB and eight versions; both are injected policy, not
validator constants. Admission never evicts a Model package implicitly or by
age. The user can explicitly remove an installed copy without touching its
source folder. Removal first moves the exact revalidated package into a private
quarantine, then removes its provenance and bytes.

Installed packages use Complete Until First User Authentication protection and
are excluded from OS backup. A protected sidecar records the manifest digest
and whether an out-of-band digest was supplied. Files-picker imports do not
supply one and are displayed as **Manual import**, never publisher-verified.
The app preserves the source folder.

Admission does not select or activate an inference runtime. A package can be
listed after integrity validation without implying that transcription is
available. Runtime selection, model compatibility, quality, memory, latency,
and energy remain separate measured gates.

## Consequences

- iOS and macOS consume the same package bytes, schema, Rust policy, C ABI, and
  typed Swift values.
- The source checkout needs Rust's `aarch64-apple-ios` and
  `aarch64-apple-ios-sim` targets to generate or verify the iOS project.
- App code owns security-scoped access, private custody, Data Protection,
  atomic installation, bounded storage, explicit removal, provenance
  presentation, and recovery cleanup.
- The keyboard never reads Model-package files or receives model metadata.

## Evidence

- `scripts/build_ios_rust_ffi.sh`
- `apps/ios/voice_input/app/voice_input_model_package_stager.swift`
- `apps/ios/voice_input/app/voice_input_model_package_installer.swift`
- `apps/ios/voice_input/app/voice_input_model_library_model.swift`
- `apps/ios/voice_input/tests/voice_input_model_package_validator_test.swift`
- `apps/ios/voice_input/tests/voice_input_model_package_installer_test.swift`
- `apps/ios/voice_input/ui_tests/voice_input_ui_test.swift`

Decision [0049](0049_ios_offline_storage_enforcement.md) adds explicit
regressions proving that byte/version admission failures leave every installed
package unchanged; History retention never evicts Model packages.
