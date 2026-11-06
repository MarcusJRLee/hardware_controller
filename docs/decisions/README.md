# Decisions

One record per topic, stating what is decided now and why. When a decision
changes, edit its record in the same PR as the behavior and say what changed;
Git keeps the history. The 63 numbered records these replace are at
[`3ddc739`](https://github.com/MarcusJRLee/hardware_controller/tree/3ddc739/docs/decisions).

| Record | Covers | Former numbers |
| ------ | ------ | -------------- |
| [Platform and scope](platform_and_scope.md) | Native stack, platforms, Voice pipeline shape, CUJ-first delivery. | 0001, 0029 |
| [Portable Voice engine](portable_voice_engine.md) | Rust core, versioned C ABI, Swift adapter, single retention policy. | 0035, 0039, 0057 |
| [Inputs, Profiles, and Actions](inputs_and_actions.md) | Exclusive Device ownership, Profiles, keyboard fallback, Voice triggers. | 0004, 0014, 0016, 0018, 0034 |
| [Visual design](visual_design.md) | Device-centered direction, window navigation, Center Signal icons. | 0003, 0008, 0013, 0063 |
| [macOS text delivery](macos_text_delivery.md) | Target capture, live composition, terminal and web delivery, HUD. | 0002, 0005, 0006, 0007, 0009 |
| [macOS speech capture](macos_speech_capture.md) | Sessions, finalization, audio ownership, routes, microphone choice. | 0005, 0010, 0011, 0012, 0015, 0017, 0022 |
| [Local AI formatting](local_ai_formatting.md) | Local AI Dictation, providers, Styles, casing, lists, Dictionary. | 0020, 0021, 0053, 0054, 0058 |
| [Voice History](voice_history.md) | Sessions and results, retention, crash recovery, import, archives. | 0030, 0031, 0032, 0036, 0038, 0043 |
| [Model packages](model_packages.md) | Package format, iOS installation, bundled starter, pinned downloads. | 0037, 0041, 0061, 0062 |
| [Speech recognition runtime](asr_runtime.md) | transcribe.cpp, the bridge, iOS live decoding, macOS XPC service. | 0042, 0055, 0056, 0060 |
| [iOS capture](ios_capture.md) | App-owned capture, Keychain handoff, system surfaces, lifecycle. | 0040, 0046, 0050 |
| [iOS keyboard delivery](ios_keyboard_delivery.md) | Styles, field safety, stale service, bounded insertion recovery. | 0044, 0045, 0047, 0048 |
| [Local-only boundary](local_only_boundary.md) | Provider locality, the only network code, offline checks. | 0033, 0049 |
| [Identity and licensing](identity_and_licensing.md) | Apache 2.0, ownership, app identity, publication. | 0024–0028 |
| [Builds and workflow](builds_and_workflow.md) | Personal installs, version approval, branches, landing, CI lanes, toolchain. | 0019, 0023, 0051, 0052, 0059 |

Each record leads with its context and a decision matrix (options as columns,
criteria as rows), then the decision and its consequences. Mark claims not yet
measured on a device as open evidence.
