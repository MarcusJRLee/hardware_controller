# Public repository migration

Keep the existing GitHub repository private until this runbook is complete.
This replaces it with one repository at the same URL; it does not maintain two
hosted repositories.

## Preconditions

- Merge every approved private pull request into `main`.
- Confirm `NOTICE` names the current individual copyright owner. Longdevity LLC
  formation and ownership transfer are future work, not publication gates.
- Open [GitHub email settings](https://github.com/settings/emails), enable
  **Keep my email addresses private** and **Block command line pushes that
  expose my email**, then copy the generated `@users.noreply.github.com`
  address shown there.
- Confirm the primary checkout has an ignored `.env.local` and a clean `main`.

## Back up private-only state

Choose an absolute private archive directory outside this repository and set
`private_archive_root` to it. A Git bundle preserves refs and commits, but not
GitHub Release assets or hosted pull-request metadata. The private repository
currently has a draft `v1.4.0` Release with two assets that must be downloaded
before deletion.

Run from the private repository root:

```bash
(
set -euo pipefail
private_archive_root=""
# Set private_archive_root before continuing.
test -n "$private_archive_root"
[[ "$private_archive_root" == /* ]]
[[ "$private_archive_root" != "$PWD" ]]
[[ "$private_archive_root" != "$PWD"/* ]]

mkdir -p "$private_archive_root/releases/v1.4.0"

git fetch origin --prune --tags
git bundle create "$private_archive_root/private_history.bundle" --all
git bundle verify "$private_archive_root/private_history.bundle"

gh release view v1.4.0 \
  --repo MarcusJRLee/hardware_controller \
  --json name,tagName,isDraft,isPrerelease,createdAt,body,assets \
  > "$private_archive_root/releases/v1.4.0/release.json"
gh release download v1.4.0 \
  --repo MarcusJRLee/hardware_controller \
  --dir "$private_archive_root/releases/v1.4.0"
test -f "$private_archive_root/releases/v1.4.0/release.json"
test -f "$private_archive_root/releases/v1.4.0/Hardware.Controller-1.4.0.dmg"
test -f "$private_archive_root/releases/v1.4.0/Hardware.Controller-1.4.0.release.md"
shasum -a 256 "$private_archive_root"/releases/v1.4.0/*

gh pr list --repo MarcusJRLee/hardware_controller \
  --state all --limit 1000 \
  --json number,state,title,body,author,baseRefName,headRefName,mergedAt,url \
  > "$private_archive_root/pull_requests.json"
gh issue list --repo MarcusJRLee/hardware_controller \
  --state all --limit 1000 \
  --json number,state,title,body,author,url \
  > "$private_archive_root/issues.json"
)
```

Verify the bundle, release metadata, both release assets, checksums, and hosted
metadata exports from the private archive directory before continuing. The
JSON exports are summaries; GitHub review threads and other hosted UI metadata
are intentionally not migrated. Keep the archive private because it contains
the original history, author metadata, and private release artifacts.

## Prepare the clean root

Run from the private repository root:

```bash
(
set -euo pipefail
mkdir -p local/public_repository_migration/public_root
test -z "$(find local/public_repository_migration/public_root \
  -mindepth 1 -maxdepth 1 -print -quit)"

git archive main \
  | tar -x -C local/public_repository_migration/public_root

cp .env.local local/public_repository_migration/public_root/.env.local
chmod 600 local/public_repository_migration/public_root/.env.local

git -C local/public_repository_migration/public_root init -b main
public_author_name="$(gh api user --jq .login)"
public_author_email=""
# Paste the exact noreply address copied from GitHub email settings.
test -n "$public_author_email"
[[ "$public_author_email" == *@users.noreply.github.com ]]
git -C local/public_repository_migration/public_root \
  config user.name "$public_author_name"
git -C local/public_repository_migration/public_root \
  config user.email "$public_author_email"
git -C local/public_repository_migration/public_root add --all
git -C local/public_repository_migration/public_root \
  commit -m "Initial public source release"
)
```

Audit the independent repository before touching GitHub:

```bash
test "$(git -C local/public_repository_migration/public_root \
  rev-list --count --all)" = 1

git -C local/public_repository_migration/public_root \
  log --format='%H %an <%ae>' --all
git -C local/public_repository_migration/public_root status --short
git -C local/public_repository_migration/public_root \
  check-ignore -q .env.local
test -z "$(git -C local/public_repository_migration/public_root \
  ls-files .env.local)"

source .env.local
gmail_domain="$(printf '@%s.%s' gmail com)"
private_home="$(printf '%s/' "$HOME")"

rg --fixed-strings "$HC_EXPECTED_TEAM_ID" \
  local/public_repository_migration/public_root
rg --fixed-strings "$gmail_domain" \
  local/public_repository_migration/public_root
rg --fixed-strings "$private_home" \
  local/public_repository_migration/public_root
```

The privacy scans must produce no output. Generic paths in sanitized test
fixtures are allowed; the current operator's actual home path is not. Inspect
the complete tracked file list, license, notice, security policy, icon, and
repository URL before continuing.

## Replace the private GitHub repository

1. In the old repository, open **Settings → General → Danger Zone** and delete
   `MarcusJRLee/hardware_controller` only after verifying the external private
   archive, including the draft Release assets.
2. Recreate it privately from the audited root:

   ```bash
   gh repo create MarcusJRLee/hardware_controller \
     --private \
     --source local/public_repository_migration/public_root \
     --remote origin \
     --push
   ```

3. Confirm GitHub shows one branch, one root commit, no tags, no Releases, the
   expected noreply author, `LICENSE`, `NOTICE`, `SECURITY.md`, and Signal
   Bridge.
4. Do not import, mirror, or push any ref from the private-history repository.

## Configure GitHub before publication

Configure the replacement while it remains private where the account plan
permits it, then confirm the controls again immediately after publication:

1. Add a `main` ruleset that requires pull requests and blocks force pushes and
   branch deletion.
2. Restrict GitHub Actions workflow permissions to read-only unless a specific
   workflow requires more.
3. Enable the dependency graph, Dependabot alerts, and Dependabot security
   updates.
4. Enable CodeQL default setup for Swift.
5. Enable secret scanning and push protection.
6. Enable private vulnerability reporting.

## Publish

1. Run the clean-root audit again against the GitHub clone.
2. Change repository visibility from private to public.
3. Verify rules, security features, the security-reporting link, license and
   notice, branch count, commit count, tags, and Releases.
4. Keep binary distribution separate. Do not create a tag, DMG, or GitHub
   Release without explicit release approval.

After GitHub verification:

1. Keep the external private archive; it is not a second hosted repository.
2. Verify the clean checkout still contains an ignored, untracked
   `.env.local` with mode `600`.
3. Retire the old private-history checkout so it cannot push predecessor refs
   to the replacement URL.
4. Promote the clean root to the canonical local project path and verify it has
   one root commit, one `main` branch, one worktree, and the replacement
   `origin`.

Have Codex perform the local checkout swap after the hosted replacement is
verified. Do not recursively delete the old checkout by hand while the clean
root is nested inside it.

## Future Longdevity LLC transition

After forming Longdevity LLC:

1. Execute a signed written assignment from Marcus John Rice Lee to Longdevity
   LLC.
2. Record the effective ownership change in a new decision.
3. Update `NOTICE`, app metadata, README, contribution policy, and licensing
   authority in one pull request.
4. Do not rewrite earlier individual-ownership history.
