<!-- mjrlee-repo-kit:rules:begin (managed; edit the kit) -->

- Be extremely concise (unless I ask you to explain something), technical,
  accurate.
- Optimizing user experience, agent developer experience, and human developer
  experience is very important. All three should improve continuously; no change
  may degrade any of them.
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
- Leave no vestiges. Once a one-time migration, compatibility shim, or
  transition step has run everywhere it must, delete it along with its tests,
  docs, ignore entries, and comments about the old state.
- Files & dirs: lowercase_with_underscores. Never use dashes for files & dirs,
  except inside skill trees (`skills/<name>/`, whose spec requires dashes) and
  for names a tool mandates (e.g. `pnpm-lock.yaml`, git's hook names in
  `.lefthook/<hook>/`).
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
- Keep durable knowledge (runbooks, gotchas, decisions, project state) in the
  repo, where any agent or human finds it: the owning module's README, or
  AGENTS.md for repo-wide rules. Never in provider-specific agent memory.
- Markdown lives under `docs/` or as a directory's `README.md`, one place per
  kind of information; skill trees and `.github/` (layouts a tool fixes) are
  allowed too. Any other location is listed with its reason in
  `.mjrlee_repo_setup/markdown_paths.toml`, and the entry is deleted with the
  file.
- Anything an agent starts or creates on the machine (containers, images,
  volumes, servers, background processes, caches, worktrees, temp files) must be
  torn down or bounded before finishing, so repeated work does not exhaust disk,
  memory, or CPU over time.
- [Docker] Label every container, image, volume, and network a repo creates with
  `mjrlee.owner` (`repo/module`), `mjrlee.purpose` (one sentence), and
  `mjrlee.lifetime`: `ephemeral` (delete once unused), `cache` (rebuildable;
  delete to reclaim space), or `persistent` (holds state; delete only with the
  owner's approval). Compose files set `labels` on each service and its `build`;
  label a named volume only when first adding it, since Compose offers to delete
  an existing volume whose labels change. Audit or clean up with
  `uv run --no-project python .mjrlee_repo_setup/hooks/docker_resources.py`
  (`--help` for commands).
- [UI] UIs should be simple, clean, and beautiful - not cluttered or hectic.
  There should be an intentional and pronounced style that is documented in the
  root README.md of the repo - if not present ask for one and place it there.
  There should be prosidy - all choices should be intentional and directed
  toward the central purpose and style. Default to no colors and no borders then
  add borders and colors in minimally only where necessary.
- [Roadmap] Committed work lives in `docs/roadmap/<slug>.md`, one file per
  outcome; ideas without a commitment go in `docs/roadmap/README.md` with the
  event that would trigger them. Run
  `uv run --no-project python .mjrlee_repo_setup/tools/roadmap.py` (`--help` for
  commands); it renders the gitignored `docs/roadmap/index.md`. With no task
  named, run `roadmap.py claim`: it pushes branch `roadmap/<slug>` (the claim)
  and sets up `.worktrees/<slug>` to work in. The PR that finishes an item
  deletes its file and its slug from every `depends_on`. Record an external
  blocker as an `executor: human` item that others depend on.
- [Git] Make all repository changes on a dedicated branch and deliver them
  through a pull request; modify the default branch or use any non-PR workflow
  only when the user explicitly requests and approves that exception.
- [Git] A PR that needs an unmerged PR's work may stack on its branch. Once the
  base squash-merges, run `git rebase --onto origin/main <old base tip>` and
  `git push --force-with-lease`; the pre-push hook allows force pushes only to
  unprotected branches whose remote tip the branch already held.
- [Git] Create worktrees only as `.worktrees/<name>` in the main checkout (a
  hook blocks other paths, except Claude desktop's fixed `.claude/worktrees/`,
  and routes Claude Code's own worktrees to `.worktrees/`), and remove each one
  with its local branch once its PR merges. The main checkout stays on the
  default branch; a hook switches it back.
- [GitHub] GitHub CLI credentials live in the macOS Keychain. Sandboxed `gh`
  commands cannot read them and may falsely report an invalid token. Run `gh`
  with scoped Keychain access and verify there before asking the user to
  reauthenticate. Never copy the token into an environment file or plaintext
  GitHub config.
- [Testing] Modules with behavioral logic deserve a concise colocated
  `FILENAME_test.EXT`. Files without logic usually don't: thin wrappers,
  re-exports, declarations, styles, generated code, and config or data files.
  Use judgment; a config's invariants are usually better enforced by validation
  in the module that owns the rule (run by lint or at load) than by testing the
  config itself.
- [Testing] Test logic should be as concise as possible while still getting full
  test coverage. This means using shared logic sensibly to keep actual test
  functions scanable.
- [Testing] Always run tests and type checks on any lines of code you change
  before finishing.
- [Testing] Put verification pages and screenshots in the gitignored `tmp/`.
  After the user reviews them, delete the files the thread created.
- Begin every reply by addressing me as "Ser".

<!-- mjrlee-repo-kit:rules:end -->

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

### Landing PRs

- You may squash-merge PRs you opened once required checks pass. Never merge
  others' PRs or bypass checks.
- Land one PR at a time as `docs/CONTRIBUTING.md` "Landing" describes.

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
