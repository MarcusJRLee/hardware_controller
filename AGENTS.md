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

## Project specific intructinos

### Start here

- Read `README.md`, `docs/product_brief.md`, `docs/game_plan.md`,
  `docs/architecture.md`, and every relevant decision record before changing
  product behavior.
- Treat `docs/open_questions.md` as the approval gate. Do not create the Xcode
  project or product code until its Gate 0 questions are resolved by the user.
- Update the relevant docs and decision records when a product, architecture,
  privacy, permission, or distribution decision changes.
- Do not edit files outside this repository without explicit permission.

### Product boundaries

- Build a native macOS hardware-control app. The first supported device is the
  VEC Infinity 3 USB Foot Pedal, but no domain or UI layer may depend directly
  on that model.
- Keep all app data and processing local. Do not add analytics, telemetry,
  accounts, remote APIs, cloud storage, network entitlements, or dependencies
  that call home without explicit approval.
- Optimize the input-to-action hot path for deterministic low latency. Hardware
  callbacks, event decoding, and action dispatch must not wait on the main
  actor, UI rendering, persistence, logging, or network work.
- The center pedal is the first-use focus. Left and right controls must still be
  independently configurable in the first release.
- Preserve momentary and toggle interaction semantics as first-class concepts;
  do not implement either as UI-only special cases.

### Domain language

- **Device**: one connected physical controller.
- **Control**: one independently actuated input on a Device. Use `pedal` only in
  Infinity-specific code and copy.
- **Control event**: a timestamped Control transition or value change.
- **Driver**: a Device-specific adapter that discovers hardware and converts
  raw input into Control events.
- **Action**: behavior the app can execute.
- **Binding**: the mapping from a Control and interaction mode to an Action.
- **Profile**: a versioned collection of Bindings.
- **Momentary**: begin on press and end on release.
- **Toggle**: alternate between begin and end on successive presses.

### Engineering

- Use Swift 6 with strict concurrency checking. Prefer immutable, `Sendable`
  values across isolation boundaries.
- Keep IOKit, AppKit, Accessibility, persistence, and other system APIs behind
  narrow protocols. Domain logic must run in tests without physical hardware or
  macOS permission prompts.
- Model errors and state transitions explicitly. Avoid force unwraps, forced
  casts, implicitly unwrapped optionals, and swallowed errors.
- Keep the main actor for presentation state only.
- Use dependency injection at process boundaries; avoid global mutable state
  and singleton service locators.
- Prefer Apple frameworks and zero third-party runtime dependencies for the
  first release.
- Store configuration in a versioned, local format with atomic writes and
  explicit migrations. Never commit user configuration, raw logs, or secrets.
- Use unified logging with privacy annotations. Raw HID reports are debug-only
  and must not be emitted by release builds.
- Files and directories use `lowercase_with_underscores` except platform and
  ecosystem conventions such as `README.md`, `AGENTS.md`, and Swift type names.
- Comments are concise sentences that explain why, invariants, or non-obvious
  system behavior.
- Use decision matrices instead of pros/cons lists.

### Verification

- Add focused unit tests for every file containing domain or system-boundary
  logic. Test files mirror their source name in the appropriate test target.
- Use recorded, sanitized HID report fixtures for driver decoding tests.
- Test press, release, repeat suppression, simultaneous controls, reconnect,
  disconnect-while-active, permission denial, corrupted configuration, and
  migration behavior.
- Measure input callback to action-dispatch latency with a monotonic clock.
  Report p50, p95, p99, maximum, and sample count; an average alone is not
  sufficient.
- Run formatting, build, unit, integration, and UI checks that cover every
  changed line before handing work back.
- Verify UI changes in light mode, dark mode, increased contrast, reduced
  motion, keyboard navigation, and at least one large Dynamic Type setting.

### Documentation

- Keep `README.md` as the human entry point and command index.
- Keep `docs/product_brief.md` to product scope and canonical language.
- Keep `docs/game_plan.md` to milestones, gates, risks, acceptance criteria, and
  remaining work.
- Keep `docs/architecture.md` to current component boundaries, data flow,
  concurrency, persistence, security, and performance design.
- Record durable decisions under `docs/decisions/`; never rewrite a superseded
  decision as if the earlier choice did not happen.
- Mark unverified hardware claims as hypotheses until measured against the
  physical device.

### Personal builds and releases

- Keep signing identities and Team identifiers in ignored `.env.local` files.
  Build every app intended for `/Applications` with an explicit Apple
  Development identity and verify it against `HC_EXPECTED_TEAM_ID`. Never
  install or hand off an ad-hoc-signed build.
- Keep one canonical `/Applications/Hardware Controller.app`; quit it before
  replacing it, verify the installed signature, then launch that exact bundle.
- After every repository change, build and install the current source at the
  canonical `/Applications/Hardware Controller.app`, then verify and launch it.
- Treat version metadata as unreleased until the user explicitly approves that
  exact version for release. Never create a release tag, GitHub Release, DMG,
  or release record, or run `scripts/build_release.sh`, without that approval.
- Preserve both `CFBundleShortVersionString` and `CFBundleVersion` during
  routine changes. An agent may recommend changing either value, but must not
  apply the exact new value without explicit user approval.
