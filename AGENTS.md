<!-- mjrlee-repo-kit:rules:begin (managed; edit the kit) -->

- Be extremely concise (unless I ask you to explain), technical, and accurate.
- User, agent-developer, and human-developer experience should all improve
  continuously, and no change may degrade any of them.
- Choose the most technically correct design despite upfront cost: modular,
  reused rather than duplicated, clear, maintainable, forward-compatible,
  delivered iteratively, and shaped to eliminate drift.
- Compare options with a decision matrix (options as columns, criteria as rows),
  never a pros/cons list.
- Write strongly typed code. Never silence a type error with `as any`,
  `as never`, or a double cast (`x as never as T`); fix the root cause, and fix
  resolver/schema mismatches at the declaration, not the call site.
- Decompose by responsibility and reason to change; file length is a symptom,
  not a goal. Split mixed workflows, transport, persistence, orchestration, and
  rendering only at behavior-owned boundaries.
- Comments are punctuated sentences that explain intent, invariants, security
  boundaries, and non-obvious constraints; never restate readable code or
  comment trivial functions.
- Handle edge cases explicitly.
- Leave no vestiges: once a migration, shim, or transition step has run
  everywhere it must, delete it with its tests, docs, ignore entries, and
  comments about the old state.
- Name files and dirs lowercase_with_underscores, never dashes, except inside
  skill trees (`skills/<name>/`, whose spec requires dashes) and where a tool
  mandates a name (`pnpm-lock.yaml`, `.lefthook/<hook>/`).
- Write docs for humans: lead with the bash commands a reader needs, use tables
  for mappings like path→meaning, and cut every sentence that carries no signal.
  This block follows the same rule.
- Ask before editing files outside the current working directory, except in the
  repo's own worktree home, `~/.worktrees/<repo>/`.
- Config as code: the repo is the source of truth for anything hand-curated and
  small (under ~20 MB), whether an external system's settings (GitHub, DNS,
  launchd, app preferences) or data (a list of household automations). Keep it
  in a commented, committed file that a committed script applies; never change
  it only through a UI, console, or database, and copy any outside change back.
- Update docs in the same change as behavior; work is incomplete while
  architecture, runbooks, state, or acceptance docs describe the old behavior.
  Durable knowledge (runbooks, gotchas, decisions, project state) lives in the
  repo, in the owning module's README or `AGENTS.md` for repo-wide rules, never
  in provider-specific agent memory.
- A repo is self-contained: a fresh clone on any machine builds, tests, and
  passes its checks with only what it commits and pins, offline once its tools
  are installed. No check may read another repo, a sibling checkout, or one
  machine's paths; an extra that does must do nothing when they are absent.
- Markdown lives under `docs/` or as a directory's `README.md`, one place per
  kind of information; skill trees and `.github/` are allowed too. List any
  other path with its reason in `.mjrlee_repo_setup/markdown_paths.toml`, and
  delete the entry with the file.
- Before finishing, tear down or bound anything you started or created on the
  machine (containers, images, volumes, servers, background processes, caches,
  worktrees, temp files), so repeated work cannot exhaust disk, memory, or CPU.
- [Docker] Label every container, image, volume, and network a repo creates with
  `mjrlee.owner`, `mjrlee.purpose`, and `mjrlee.lifetime`, so anyone can tell
  what may be deleted; `.mjrlee_repo_setup/hooks/docker_labels.py` defines them
  and gates compose files. Delete a `persistent` resource only with the owner's
  approval, and never relabel an existing named volume: Compose offers to delete
  it. Audit or clean up with
  `uv run --no-project python .mjrlee_repo_setup/hooks/docker_resources.py`.
- [UI] UIs are simple, clean, and beautiful, never cluttered. The root README.md
  documents one intentional, pronounced style (ask for one if it is missing),
  and every choice serves it and the product's purpose. Start with no color and
  no borders; add them minimally, only where needed.
- [Roadmap] Committed work is one `docs/roadmap/<slug>.md` per outcome; ideas
  without a commitment go in `docs/roadmap/README.md` with the event that would
  trigger them. Manage items with
  `uv run --no-project python .mjrlee_repo_setup/tools/roadmap.py` (`--help`);
  with no task named, `roadmap.py claim` claims the next one and sets up
  `~/.worktrees/<repo>/<slug>`. The PR that finishes an item deletes its file
  and its slug from every `depends_on`. An external blocker is an
  `executor: human` item that others depend on.
- [Launch] Every repo declares `[launch] phase` (`pre_launch` or `public`, no
  default) in `.mjrlee_repo_setup/repo.toml`. Before launch, build the best
  foundation; teardowns, data wipes, and outages are fine. After launch, never
  interrupt service: every behavior change ships behind a flag (each commit
  carries `Flag: <name>` or `Flag: none (<reason>)`), schema changes expand
  before they contract and only move forward, rollouts are staged, and every
  user-facing surface has a kill switch.
- [Quiet hours] Every repo declares `[quiet_hours]` in
  `.mjrlee_repo_setup/repo.toml`: weekly windows, or `windows = []` for none.
  Inside a window, work only locally: create or push no commit and make no
  GitHub write, since each leaves a dated record; hooks deny them. Never set or
  rewrite a commit's dates. Check with
  `uv run --no-project python .mjrlee_repo_setup/hooks/quiet_hours_rule.py`.
- [Flags] Every flag lives in the repo's one flag catalog with its owner, the
  binary it gates, its default, its rules per environment, its primary and
  guardrail metrics, and a removal date the catalog's lint enforces. A flag
  provider holds only an applied copy; a drift check fails on dashboard edits.
  Evaluate at runtime where the repo has a backend, so a merged change reaches
  users within the hour without a release; otherwise evaluate at build time and
  roll out through staged releases.
- [Metrics] Dashboards are code; agents read metrics through an API or CLI.
- [Git] Deliver every change through a PR from a dedicated branch; touch the
  default branch or skip the PR only when the user explicitly approves.
- [Git] A PR may stack on an unmerged PR's branch. Once the base squash-merges,
  run `git rebase --onto origin/main <old base tip>` and
  `git push --force-with-lease`; the pre-push hook allows force pushes only to
  unprotected branches whose remote tip the branch already held.
- [Git] Create worktrees only as `~/.worktrees/<repo>/<name>`, `<repo>` being
  the main checkout's directory name, so nothing that watches or indexes the
  checkout covers them; remove each with its local branch once its PR merges.
  The main checkout stays on the default branch. Hooks block other worktree
  paths and switch the main checkout back.
- [Git] A new worktree sets itself up: its post-checkout hook runs
  `[checkout] setup` from `.mjrlee_repo_setup/repo.toml`, else the lockfile's
  install. Where that file's `[replace]` maps a command, such as `gh pr merge`,
  run the replacement; a hook denies the original.
- [GitHub] `gh` credentials live in the macOS Keychain, which sandboxed commands
  cannot read, so they may falsely report an invalid token. Run `gh` with scoped
  Keychain access and verify there before asking the user to reauthenticate;
  never copy the token into an env file or plaintext config.
- [Testing] Logic whose failure would ship a defect or block a release needs a
  concise colocated `FILENAME_test.EXT`. Thin wrappers, re-exports, constants,
  styles, declarations, generated files, one-shot operator scripts, and
  vendoring tools are exempt; `test_ownership.py` enforces each exemption by
  path (such as `scripts/data/` or `vendor_*`) or header marker, not by an
  agent's judgment. A config's invariants are usually better enforced by
  validation in the module that owns the rule (run by lint or at load) than by
  testing the config itself.
- [Testing] Keep tests as concise as full coverage allows, sharing setup so each
  test function stays scannable.
- [Testing] Run tests and type checks on every line you change before finishing.
- [Testing] Put verification pages and screenshots in the gitignored `tmp/`, and
  delete the ones you made once the user has reviewed them.
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
