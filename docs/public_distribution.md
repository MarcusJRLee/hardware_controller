# Public distribution

**Status:** Reproducible workflow prepared; no public binary release is
approved or published.

Source licensing and binary distribution are separate decisions. Run this
workflow only after the user approves the exact marketing version and build
for public release.

## Required evidence

| Gate | Required result |
| --- | --- |
| Source | Clean `main` exactly matches `origin/main`. |
| Approval | `HC_RELEASE_APPROVED_VERSION` exactly matches packaged `X.Y.Z`. |
| Signing | Developer ID Application identity, expected Team, hardened runtime, secure timestamp, and audio-input-only entitlement. |
| Notarization | Apple notary status Accepted, ticket stapled, and Gatekeeper assessment passed. |
| Artifact | Verified arm64 DMG containing the byte-identical signed app. |
| Product | Automated, physical Device, permissions, accessibility, and supported-macOS evidence accepted for the claimed scope. |
| Installation | Downloaded artifact passes a clean-account install and first-use rehearsal. |

An Apple Development identity is valid for private Applications builds but not
public distribution. Public artifacts require a Developer ID Application
certificate and Apple notary credentials stored in the macOS Keychain.

## One-time private setup

Create the ignored release configuration:

```bash
cp .env.release.example .env.release.local
# Replace every placeholder with your private Developer ID values.
chmod 600 .env.release.local
```

Store the notary credential in Keychain. `notarytool` prompts for the
app-specific password; do not place it in an environment file:

```bash
xcrun notarytool store-credentials "HardwareControllerNotary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID"
```

## Build and notarize an approved version

After explicit approval names the exact version:

```bash
set -a
source .env.release.local
set +a

approved_version=""
# Set approved_version to the exact approved X.Y.Z before continuing.
test -n "$approved_version"
export HC_RELEASE_APPROVED_VERSION="$approved_version"

scripts/build_release.sh
scripts/notarize_release.sh
```

The first script rejects a dirty branch, a non-`main` branch, remote drift,
unapproved version metadata, invalid signing, unexpected entitlements,
non-Apple runtime dependencies, or a mismatched DMG. The second requires a
timestamped Developer ID Application signature, waits for Apple notarization,
staples and validates the ticket, runs Gatekeeper assessment, rechecks the DMG,
and appends the notarized hash and submission identifier to the release
evidence.

Do not publish until the resulting DMG has been copied to a clean supported Mac
and the installation, permission, Device, Dictation, and removal workflows
have passed for the advertised scope.

## Publish the free GitHub Release

After the exact artifact receives final release approval:

```bash
test -n "${approved_version:-}"
source_commit="$(git rev-parse HEAD)"
gh release create "v$approved_version" \
  "dist/Hardware Controller-$approved_version.dmg" \
  "dist/Hardware Controller-$approved_version.release.md" \
  --repo MarcusJRLee/hardware_controller \
  --target "$source_commit" \
  --title "Hardware Controller $approved_version" \
  --generate-notes
```

Verify the public tag, artifact hash, evidence attachment, source commit, and
credential-free download. The Release is free; the Apache License 2.0 applies
to the corresponding source. Never upload `.env.release.local`, Keychain
credentials, notarization logs containing account data, or private signing
exports.
