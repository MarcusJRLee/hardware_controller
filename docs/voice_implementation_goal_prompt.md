# Voice implementation goal prompt

Copy the prompt below back into Codex after reviewing the linked plan and CUJs.
It authorizes implementation and GitHub pull requests, but not release promotion
or merging the program into `main`.

```text
Create and pursue a goal with no token budget to implement the accepted local
Voice platform roadmap to polished completion. Incur no monetary cost: do not
purchase services, models, subscriptions, hardware, certificates, or paid build
capacity. Continue autonomously until every safe, in-scope macOS and iOS
requirement is implemented, verified, documented, and integrated into the dev
branch. Do not stop merely because the work is large, slow, spans many pull
requests, or encounters an evidence gap.

Repository authority, in order:
1. AGENTS.md
2. docs/decisions/0029_local_voice_platform_expansion.md
3. docs/voice_cujs.md
4. docs/voice_platform_design.md
5. docs/open_questions.md
6. docs/product_brief.md, docs/architecture.md, docs/game_plan.md, CONTEXT.md,
   existing decisions, and platform/release runbooks

First preserve and inspect all existing uncommitted planning changes. Do not
discard user work. Reconcile contradictions in the authoritative documents
before product code, recording any durable correction in the same focused PR.
The Voice expansion gate is approved by decision 0029; do not ask me to approve
those choices again.

Operating mode:
- Make technically correct, maintainable decisions autonomously within the
  accepted scope. Do not ask preference questions when the documents, code,
  measurements, or a reversible conservative choice can resolve them.
- Research current primary platform/model documentation whenever facts may have
  changed. Treat proprietary product behavior as UX evidence, never API
  authorization.
- Exhaust all safe work around external constraints. If a physical device,
  signing service, App Review, repository rule, or tool permission prevents one
  proof, record the exact evidence gap, build the strongest automated or signed-
  device substitute available, continue every independent slice, and return to
  the gap later. Never fake evidence or bypass security/branch protections.
- Do not declare completion while any safe, relevant implementation, polish,
  testing, documentation, packaging, or installation work remains.
- Keep macOS and iOS as the implementation roadmap. Preserve clean engine and
  schema boundaries for later Android, Windows, and Linux work. Do not implement
  or prototype web/mobile web in this program.

Git and pull-request workflow:
- Use dev as the integration branch. If it does not exist, create it from the
  current main without modifying main.
- Implement every logical slice on a new codex/voice_* branch in its own Git
  worktree. Base it on the latest integrated dev state.
- Each PR must be focused and vertically useful: acceptance/docs, behavioral
  test, implementation, migration, and verification for one coherent slice.
  Avoid giant PRs, layer-only batches, unrelated cleanup, and artificial
  one-file PRs.
- Target every program PR at dev. Merge it after required checks pass when
  repository policy permits. If policy requires unavailable human review, keep
  dependent work in explicit stacked PRs and continue without bypassing it.
- Keep PR descriptions concise: CUJs covered, architecture decision, tests and
  measurements, migrations, risks, and rollback/recovery behavior.
- Never push directly to main or merge dev into main. Do not change release
  versions/build numbers, create tags, DMGs, GitHub Releases, App Store
  submissions, or release records without separate explicit approval.

Implementation method:
- Follow vertical red → green → refactor TDD. Start with CUJ M1 as the tracer.
  Add one failing behavior test, implement the complete minimum path, make it
  green, then refactor while green. Repeat.
- Test observable behavior through small public interfaces. Do not mock internal
  modules, assert private call order, or lock tests to temporary file/layout/UI
  structure. Mock only system boundaries; prefer temporary real repositories and
  sanitized audio fixtures.
- Preserve Raw, Edited, Formatted, Delivered, and corrected text as distinct
  evidence. Preserve current Hardware Controller behavior and hot-path latency
  while incrementally moving only exercised boundaries into the approved apps/
  and crates/ structure.
- Keep heavy processing in-process. Own portable behavior and model facades in
  Rust; permit optimized C/C++ kernels only behind narrow safe bindings. Select
  ASR, formatting models, and Swift/Rust FFI from measured evidence rather than
  preference.
- Implement local-only enforcement, bounded storage, migrations, recovery,
  accessibility, permissions, interruption handling, and user-visible failure
  behavior as product features, not deferred cleanup.

Testing strategy—strong but adaptable:
- Make fast CUJ contract tests the primary regression spine. They may use a
  deterministic ASR/formatting provider so model variance cannot make CI flaky.
- Use adapter integration tests for SQLite/files, App Group messaging, audio
  conversion, Accessibility delivery, lifecycle, model packages, and FFI.
- Maintain a deliberately small E2E suite for the highest-risk complete paths:
  macOS hold-to-insert-and-store, latch, focus-change recovery, retention/crash
  recovery, and offline/model fallback; iOS onboarding/keyboard fallback,
  warm keyboard capture-to-insertion, cold/suspended activation, interruption/
  stale service, and offline retention.
- Cover combinations and edge cases below E2E unless only a true UI/system test
  can establish the behavior. Do not create an E2E test for every CUJ row.
- Test generative models with semantic invariants, protected-token preservation,
  bounded quality metrics, and pinned model digests—not brittle exact prose.
- Keep UI automation anchored to accessibility identifiers and user outcomes,
  not coordinates or incidental hierarchy. Use retries only for documented
  asynchronous system boundaries, never to hide nondeterminism.
- An intentional behavior change may update a CUJ and its test in the same PR
  when the PR documents the reason and retains equivalent safety coverage.
- Run fast affected tests during each red/green loop, full repository checks
  before every PR, relevant signed/system tests at milestone boundaries, and the
  complete quality/performance matrix before final handoff.

Program sequence:
1. Integrate the approved planning/decision/CUJ baseline and establish dev/CI.
2. Deliver the macOS M1 tracer inside the existing Hardware Controller app.
3. Complete macOS capture gestures, Styles, Dictionary, spoken edits, safe
   delivery, History, retention, recovery, imported audio, local enforcement,
   model selection, UI polish, accessibility, and performance hardening.
4. Stabilize the portable Rust engine, schemas, model boundary, FFI, archive,
   and conformance tests without speculative non-Apple applications.
5. Complete the signed-device iOS Gate K0 probe and record its evidence.
6. Deliver the iOS containing app, custom keyboard, local models, History,
   onboarding, warm/cold session UX, App Group coordination, insertion,
   background/Live Activity behavior, interruption recovery, retention,
   accessibility, performance, and polish.
7. Run final cross-platform regression, privacy, migration, corruption,
   long-session, lowest-device, installation, and documentation passes.

Split or combine the sequence into focused PRs based on learned boundaries; do
not sacrifice vertical value merely to match a predetermined PR count.

Definition of done:
- Every approved macOS and iOS CUJ has implementation and appropriate contract,
  integration, E2E, performance, or signed-device evidence.
- Current macOS and iOS UI is simple, intentional, accessible, responsive, and
  verified in required appearance, contrast, motion, keyboard, and Dynamic Type
  modes.
- Local-only enforcement, storage bounds, recovery, model provenance, privacy,
  latency, memory, energy, migrations, and failure paths meet the documented
  gates or have an evidence-backed documented adjustment preserving the product
  promise.
- All required checks pass on dev. Every focused PR is merged to dev or, only
  where repository policy makes that impossible, is ready and explicitly
  ordered with no missing engineering work.
- The canonical signed macOS development app is installed, verified, and
  launched. A signed iOS development build/project is ready for installation on
  the intended device to the maximum permitted by available identities and
  hardware.
- README, product brief, architecture, game plan, CUJs, decisions, user guide,
  contributor guidance, troubleshooting, privacy, and release/install runbooks
  describe the finished dev state without stale proposal language.
- Final handoff is concise and includes: outcome, PR list, remaining external-
  owner evidence only, exact verification results, known limitations, and quick
  macOS/iOS installation and first-use instructions.
- main remains untouched. Stop after dev is ready for my final verification and
  wait for explicit approval before proposing or performing dev → main.
```
