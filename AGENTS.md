- Be extremely concise (unless I ask you to explain something), technical,
  accurate.
- Favor modularity, reuse over duplication, iteration.
- Design for maintainability, clarity, forward-compatibility.
- Prefer to make the most technically correct decisions despite upfront cost.
- Where possible, prefer designs that eliminate or minimize risk of drift or
  other issues.
- Never use pros/cons lists - instead use decision matrices when required
  (options = columns, criteria = rows).
- Always write strongly typed code. For example, never use `as never`, `as any`,
  or double-casts (`x as never as T`) to suppress TypeScript errors — diagnose
  and fix the root cause instead. Resolver/schema type mismatches must be fixed
  at the declaration site, not silenced at the call site.
- Decompose by responsibility and reason to change. File length is diagnostic,
  not an acceptance criterion. Split mixed workflows, transport, persistence,
  orchestration, and rendering only at behavior-owned boundaries.
- Comments explain intent, invariants, security boundaries, and non-obvious
  constraints. Do not comment trivial functions or restate readable code.
- Comments should always be sentences and end with punctuation.
- Handle edge cases explicitly.
- Files & dirs: lowercase_with_underscores. Never use dashes for files & dirs.
- Ensure README.md and other docs prioritise human readability. Lead with the
  bash commands a reader needs to get going. Use tables for things like
  path→meaning. Trim every sentence — if removing it doesn't lose signal, delete
  it. This file follows the same rule: every rule earns its place.
- Don't go editing files outside of the current working directory without
  explicit permission. Ask first.
- Any data source that is not expected to go beyond 20 MB in size (like a list
  of household automations) should be in a source controlled file that can hold
  comments rather than a database that is hard to edit / read.
- Update source-controlled documentation in the same change as behavior. Work is
  incomplete while architecture, runbooks, state, or acceptance docs describe
  obsolete behavior.
- [UI] UIs should be simple, clean, and beautiful - not cluttered or hectic.
  There should be an intentional and pronounced style that is documented in the
  root README.md of the repo - if not present ask for one and place it there.
  There should be prosidy - all choices should be intentional and directed
  toward the central purpose and style. Default to no colors and no borders then
  add borders and colors in minimally only where necessary.
- [Git] Make all repository changes on a dedicated branch and deliver them
  through a pull request; modify the default branch or use any non-PR workflow
  only when the user explicitly requests and approves that exception.
- [GitHub] Use the operating system credential store for GitHub authentication.
  Never copy tokens into environment files or plaintext GitHub configuration.
- [Testing] Every module with behavioral logic needs a concise colocated
  `FILENAME_test.EXT`. Thin route wrappers, re-exports, constants, styles,
  declarations, generated infrastructure, and modules without logic are exempt.
- [Testing] Test logic should be as concise as possible while still getting full
  test coverage. This means using shared logic sensibly to keep actual test
  functions scanable.
- [Testing] Always run tests and type checks on any lines of code you change
  before finishing.
- Begin every reply by addressing me as "Ser".

## Project rules

### Before changing behavior

- Read `docs/architecture.md` and the decisions it links for the area you
  touch. Update docs, journey proofs in `docs/voice_cujs.md`, and the topic's
  decision record in the same PR. Records state current decisions; edit the
  topic's record rather than adding one per change, and say what changed.
- Mark unverified hardware claims as hypotheses until measured on the device.

### Product boundaries

- Native macOS hardware-control app plus the iOS Voice Input app. The VEC
  Infinity 3 is the first Device; no domain or UI layer may depend on it.
- All data and processing stay local. No analytics, telemetry, accounts,
  remote APIs, cloud storage, network entitlements, or dependencies that call
  home without explicit approval.
- Hardware callbacks, decoding, and dispatch never wait on the main actor, UI,
  persistence, logging, or network work.
- Center pedal first; left and right stay independently configurable.
  Momentary and Toggle are first-class domain concepts, never UI-only cases.
- Use the canonical language in `docs/product_brief.md`. Say `pedal` only in
  Infinity-specific code and copy.

### Engineering

- Swift 6 strict concurrency; immutable `Sendable` values across isolation.
- IOKit, AppKit, Accessibility, persistence, and other system APIs stay behind
  narrow protocols so domain logic tests without hardware or permission
  prompts. Use dependency injection at process boundaries; no singletons or
  global mutable state.
- Typed errors and explicit state transitions. No force unwraps, forced casts,
  implicitly unwrapped optionals, or swallowed errors.
- The main actor is for presentation state only.
- Apple frameworks only at runtime unless a decision approves otherwise.
- Configuration is versioned, local, atomically written, and explicitly
  migrated. Never commit user configuration, raw logs, or secrets.
- Unified logging with privacy annotations; raw HID reports are debug-only.

### Verification

- `scripts/check.sh` (and `scripts/check_ios.sh` for iOS or shared Voice code)
  must pass before handing work back.
- Before claiming a change works, follow `.claude/skills/verify/SKILL.md`:
  drive the affected journeys on a fresh build and report evidence and gaps.
- Driver tests use recorded, sanitized HID fixtures and cover press, release,
  repeats, simultaneous Controls, reconnect, and disconnect-while-active.
- Latency claims report p50, p95, p99, max, and sample count from a monotonic
  clock.
- UI changes are checked in light, dark, increased contrast, reduced motion,
  keyboard navigation, and a large text size.

### Personal builds and releases

- Signing identities and Team identifiers live only in ignored `.env.local`.
  Every `/Applications` build uses an explicit Apple Development identity
  verified against `HC_EXPECTED_TEAM_ID`; never install an ad-hoc build.
- After every repository change, run `scripts/install_app.sh`. It replaces the
  single canonical `/Applications/Hardware Controller.app`, verifies it, and
  launches that exact bundle; do not install any other way.
- Never change `CFBundleShortVersionString` or `CFBundleVersion`, run
  `scripts/build_release.sh`, or create a tag, DMG, GitHub Release, or release
  record without explicit approval of that exact version.
