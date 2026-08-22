# Contributing

Issues, design discussion, documentation, tests, and code contributions are
welcome. Search existing issues before opening a new one. For substantial
behavior or architecture changes, open an issue before implementation so the
scope and acceptance evidence are explicit.

## Start locally

Requirements: Apple silicon, macOS 15 or later, and Xcode 26 or a compatible
Swift 6 toolchain.

```bash
git clone https://github.com/MarcusJRLee/hardware_controller.git
cd hardware_controller
swift run HardwareController --demo
```

Demo mode is deterministic and requires no Device, Apple signing identity, or
privacy permission. Run the complete automated baseline before opening a pull
request:

```bash
scripts/check.sh
```

See the [contributor guide](docs/contributor_guide.md) for target ownership,
test placement, hardware fixtures, and signed Device testing.

## Pull requests

- Keep each pull request focused on one reason to change.
- Add concise colocated tests for every changed behavior.
- Update current documentation with behavior, architecture, privacy,
  permission, or distribution changes.
- Add or supersede a decision record when a durable decision changes.
- Preserve Swift 6 strict concurrency and immutable `Sendable` values across
  isolation boundaries.
- Keep IOKit, AppKit, Accessibility, persistence, and system APIs behind their
  existing narrow boundaries.
- Do not change version or build metadata, create release artifacts, or publish
  a Release without explicit approval for that exact version.

GitHub requests review from the repository owner. Automated verification and
CodeQL must pass, review threads must be resolved, and accepted changes are
squash-merged into `main`.

## Privacy and hardware evidence

Never submit credentials, personal configuration, transcripts, raw logs,
Device serial numbers, unsanitized HID captures, private local paths, signing
identities, or Apple Team identifiers. Sanitize recorded HID fixtures and mark
unverified hardware claims as hypotheses. Report vulnerabilities through
[`SECURITY.md`](SECURITY.md), not a public issue.

## Contribution license

The project is licensed under the
[Apache License 2.0](LICENSE). Under Section 5, an intentional contribution
submitted for inclusion is licensed under Apache 2.0 unless you explicitly
state otherwise. You retain copyright in your contribution and certify that
you have the right to submit it. No contributor license agreement or copyright
assignment is currently required.
