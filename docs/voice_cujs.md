# Critical user journeys

Each journey names its contract and the automated tests that prove it. A
change to a journey updates this table, its tests, and its decision in the
same PR. Gaps that need a signed device or physical hardware are tracked in the
[game plan](game_plan.md#open-evidence).

## How journeys are proven

| Level | Proves | Where |
| --- | --- | --- |
| Contract | Pure state machines, formatting, retention, edits, Profile edits. | `Tests/HardwareControllerCoreTests`, `crates/*` |
| Adapter | Real SQLite, files, Keychain, FFI, audio conversion, transcribe.cpp. | `Tests/HardwareControllerMacTests`, `Tests/voice_asr_bridge_tests`, `apps/ios/voice_input/tests` |
| Process | The runtime against a fake process seam (no UI callbacks mocked). | `Tests/HardwareControllerAppTests` |
| System | Launched app, real UI, simulator. | `scripts/smoke_app.sh`, `apps/ios/voice_input/ui_tests`, `scripts/check_ios.sh` |
| Cross-language | One fixture read by Rust, Swift, and C. | `Tests/cuj/` |

Rules: mock only system boundaries (microphone, clock, filesystem faults,
target field, OS lifecycle, model runtime). Assert user-visible outcomes and
typed state, never private call order, exact model prose, or sleeps. Every
workflow must be idempotent under duplicated stop, callback, and completion
events.

## macOS

| ID | Journey | Contract | Proof |
| --- | --- | --- | --- |
| H1 | Press a pedal | Exact device match, exclusive open, three Controls, simultaneous presses, no pointer clicks. | `infinity_3_driver_test`, `infinity_hid_manager_test`, `hardware_input_source_tests`, recorded fixtures |
| H2 | Hold or toggle an Action | Momentary/Toggle semantics; duplicate suppression; every exit ends active Actions once; p99 ≤ 15 ms. | `binding_engine_tests`, `controller_runtime_test`, `action_executor_tests` |
| H3 | Edit and switch Profiles | Pure typed edits; atomic save before adoption; active Actions end first. | `profile_edit_test`, `profile_tests`, `profile_store_tests`, `application_runtime_test` |
| H4 | Use a keyboard fallback | Exact chord, active Profile only, shared ownership with the pedal. | `keyboard_fallback_input_source_test`, `application_runtime_test` |
| H5 | Install and launch | Only an unexpired Apple Development build passes policy; one canonical copy; the installed bundle launches and stays up; CI smoke-launches every packaged build. | `scripts/install_app_test.sh`, `scripts/smoke_app_test.sh`, `scripts/smoke_app.sh` |
| M1 | Hold to dictate | One session; one validated insertion; audio and every text stage stored; copyable on failure. | `local_ai_dictation_controller_test`, `voice_session_history_test`, `sqlite_voice_session_store_test` |
| M2 | Latch a long prompt | First key-down begins; hold finishes on release; double press latches and finishes once. | `voice_trigger_test`, `voice_keyboard_trigger_controller_test` |
| M3 | Format for purpose | Five Styles from one Raw; validated list blocks; safe flattening; protected tokens kept. | `voice_formatted_document_builder_test`, `voice_formatted_text_renderer_test`, `voice_formatting_draft_normalizer_test`, `voice_casing_policy_test`, `voice_list_intent_test` |
| M4 | Backtrack explicitly | Exact commands become replayable typed edits; near misses stay text. | `voice_spoken_edit_engine_test`, `voice_spoken_edit_replayer_test` |
| M5 | Keep target ownership | Captured route and empty caret revalidated; changes stop delivery with a typed reason. | `focused_text_target_tests`, `transcript_writer_tests`, `terminal_text_delivery_tests` |
| M6 | Browse and reuse History | Search every stage; corrections, reruns, and re-delivery append; Dictionary suggestions need confirmation. | `voice_history_service_test`, `voice_history_model_test`, `voice_history_redeliverer_test`, `voice_history_reformatter_test`, `voice_dictionary_suggestion_test` |
| M7 | Bound storage | Age, bytes, count, low disk; transcripts kept; active, pinned, recovery audio protected. | `sqlite_voice_history_retention_store_test`, `voice_history_retention_planner_test`, `Tests/cuj/voice_retention_v1.json` |
| M8 | Recover from a crash | Partial and orphan audio become Recovery sessions; corrupt rows isolated; corrupt DB preserved. | `voice_history_reconciler_test`, `voice_history_recovery_test` |
| M9 | Stay local | Remote-capable providers rejected before invocation; Edited fallback; audio kept on ASR failure. | `local_ai_refinement_router_test`, `ollama_local_ai_refiner_tests`, `local_ai_dictation_controller_test` |
| M10 | One session for every trigger | Pedal, chord, and menu bar share one dispatcher. | `coordinated_dictation_dispatcher_tests`, `dictation_command_dispatcher_tests` |
| M11 | Portable retention | One Rust policy behind a caller-owned C ABI. | `scripts/check_rust.sh`, `voice_history_retention_planner_test`, `Tests/voice_ffi/retention_smoke.c` |
| M12 | Import a recording | Bounded copy, local ASR and formatting, source untouched, never auto-inserted. | `voice_audio_import_service_test`, `voice_audio_artifact_importer_test` |
| M13 | Admit Model packages | Bounded manifest, inventory, license, and SHA-256 verification. | `crates/voice_models`, `portable_voice_validator_test`, `Tests/cuj/voice_model_package_v1` |
| M14 | Move a session | V1 archive round trip; identical import is a no-op; conflicts fail closed. | `voice_history_exporter_test`, `voice_history_archive_importer_test`, `Tests/cuj/voice_history_archive_v1` |
| M15 | Set up speech | transcribe.cpp is the default; Dictation is refused until its pinned package is downloaded and Rust-admitted, or Apple is explicitly confirmed. | `speech_engine_model_test`, `speech_engine_session_factory_test`, `asr_model_downloader_test`, `application_preferences_test` |
| M16 | Survive a speech crash | Decode in the XPC service; a crash, hang, or repeat crash falls back to Apple on the same audio and is announced. | `transcribe_cpp_speech_engine_test`, `transcribe_cpp_speech_recognition_session_test`, `asr_service_core_test`, `scripts/check_speech_engine.sh` |
| M17 | Know which engine ran | History records engine, package, and fallback; sessions from before 0060 read as Apple. | `voice_history_column_codec_test`, `speech_engine_test` |
| M19 | Ask Gemini without leaving the app | One final question; never touches the focused app; needs no Accessibility; opens a new chat; ⌘W closes one chat and ⌘⇧W the panel; zoom is remembered per site; placement prefers the lock point, then another display; Gemini changes fail to the clipboard. | `ask_gemini_controller_test`, `ask_gemini_panel_layout_test`, `ask_gemini_chat_test`, `coordinated_dictation_dispatcher_tests`, `action_executor_tests`, `application_runtime_test`, `profile_store_tests`, `application_preferences_test` |
| M18 | Say a numbered term | "P R forty-four" becomes `PR 44` through a `{number}` Dictionary slot; numbers without its words stay spoken; casing and validation keep it. | `personal_dictionary_replacement_applier_test`, `spoken_number_parser_test`, `voice_casing_policy_test`, `local_ai_dictation_tests` |

## iOS

| ID | Journey | Contract | Proof |
| --- | --- | --- | --- |
| I0 | Dictate in the app | Fresh install to text: capture, ASR, formatting, result with Copy/Share, History search; survives a moved container. | `testFreshInstallDictatesIntoSearchableHistory` (recorded clip replaces only the microphone), `voice_input_history_session_test` |
| I1 | Onboard locally | A fresh install provisions the pinned starter model; microphone asked on first tap with exact denial recovery; imported packages still admitted. | `voice_input_starter_model_test`, `voice_input_asr_model_registry_test`, `voice_input_dictation_presentation_test`, `voice_input_onboarding_policy_test`, `voice_input_model_package_{stager,validator,installer}_test`, `testSettingsShowTheVerifiedModelSetupAndStorage` |
| I2 | Dictate from the keyboard | Real local ASR, live pause-cut decoding, History commit before publish, one insertion. | `voice_input_asr_workflow_test`, `voice_input_local_transcriber_test`, `voice_input_live_audio_tap_test`, `voice_input_session_finalizer_test`, `voice_asr_bridge_test.c` |
| I3 | Start when the app is cold | System surfaces foreground the app honestly. | `voice_input_system_capture_test`, `scripts/check_ios_system_capture_metadata.sh` |
| I4 | Type without Full Access | Letters, numbers, symbols, auto-capitals, and double-space period work; voice explains what it needs. | `voice_input_keyboard_policy_test`, `voice_input_keyboard_layout_test` |
| I5 | Respect unsupported fields | Constrained or sensitive fields disable voice only. | `voice_input_host_field_policy_test`, `voice_input_delivery_target_policy_test` |
| I6 | Choose a Style | Keyboard Style travels with its exact session. | `voice_input_style_test`, `voice_input_style_mapping_test`, `voice_input_style_preference_test`, `testStyleMenuOffersEveryCanonicalStyle` |
| I7 | Survive interruptions | Typed lifecycle policy; no auto-resume; partial audio recovered. | `voice_input_lifecycle_policy_test`, `voice_input_lifecycle_notification_mapper_test`, `voice_input_capture_service_test` |
| I8 | Detect a stale service | Heartbeats expire within 3 s; stale state cannot revive delivery. | `voice_input_keychain_store_test`, `voice_input_keyboard_policy_test` |
| I9 | Recover failed insertion | One retry or a ten-minute local copy, only for the exact result and field. | `voice_input_insertion_recovery_policy_test` |
| I10 | Stay offline within limits | No network code; age, bytes, count, reserve; Models never evicted implicitly. | `voice_input_history_repository_test`, `voice_input_history_retention_preferences_test`, `scripts/check_ios_local_only.sh`, `testSettingsShowTheVerifiedModelSetupAndStorage` |
| I11 | Capture without the keyboard | Control Center, Lock Screen, Action button, Siri, Live Activity stop. | `voice_input_system_capture_test`, `testSettingsShowTheVerifiedModelSetupAndStorage` |
| I12 | Delete History | One dictation or all of it, with its audio; an in-progress capture survives; the empty state survives relaunch. | `voice_input_history_repository_test`, `voice_input_history_model_test`, `testHistoryDeletesOneDictationThenClearsAll` |
| I13 | Download a better model | One tap fetches a pinned package, verifies every digest, admits it through Rust, and activates it; a corrupt file installs nothing. | `asr_model_catalog_test`, `asr_model_package_assembler_test`, `voice_input_model_library_model_test`, `voice_input_model_choice_test`, `testSettingsShowTheVerifiedModelSetupAndStorage` |

## Accepted defaults

macOS audio retention defaults to 90 days, 2 GiB, or 5,000 recordings; iOS to
90 days, 1 GiB, or 2,000. Recoverable partial audio is kept 24 hours. Both
were accepted with [Platform and scope](decisions/platform_and_scope.md).
