"""Git hook: every installed kit file matches its hash in `kit.lock`.

Kit files are generated, so an edit to one is lost on the next sync; the usual
culprit is a formatter or linter that was passed the file explicitly and so
skipped its excludes. The sync records the SHA-256 of each file's UTF-8 text,
newlines read as `\\n`, under a `file:<path>` key; this hook recomputes it from
the repo alone. `sync_repo_kit_test` runs this hook on a synced repo, so the
two cannot disagree on the format. Portions of shared files (`AGENTS.md`,
settings) are left to `sync_repo_kit.py --check`.

    kit_drift.py pre-commit                # What this commit will hold.
    kit_drift.py pre-push <remote> <url>   # Each pushed tip; ref lines on stdin.

Pre-commit reads a staged path from the working tree, where lefthook has hidden
its unstaged hunks and a formatter's fixes wait for `stage_fixed`, and any
other path from the index. Lefthook runs commands before scripts when
`parallel` is off (`lefthook_contract_test` pins it), so this sees the commit's
formatter fixes; in a parallel hook it can race them, and the next commit or
the push catches what it missed. A repo with no committed lock passes.

Exit codes: 0 no drift, 1 drift.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from collections.abc import Callable, Iterable, Sequence
from pathlib import Path
from typing import Final

import git_queries

LOCK_PATH: Final = ".mjrlee_repo_setup/kit.lock"
FILE_KEY: Final = "file:"
FIX: Final = (
    "Kit files are generated, so never edit them in place: restore each one"
    " from a commit where it matches the lock"
    " (`git restore --source=HEAD --staged --worktree -- <path>`, or"
    " `--source=origin/HEAD` when HEAD has the edit). A formatter or"
    " linter given explicit paths may skip its excludes: pass its"
    " force-exclude flag (ruff: `--force-exclude`)."
)


def digest(data: bytes) -> str | None:
    """Return the lock's hash of a file's bytes; None when not UTF-8.

    Matches the sync, which hashes `Path.read_text`: universal newlines.
    """

    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def locked_files(lock: bytes) -> dict[str, str] | None:
    """Return installed path → hash from the lock; None when malformed."""

    try:
        loaded: object = json.loads(lock)
    except ValueError:
        return None
    units = loaded.get("units") if isinstance(loaded, dict) else None
    if not isinstance(units, dict):
        return None
    files: dict[str, str] = {}
    for key, value in units.items():
        if not isinstance(key, str) or not isinstance(value, str):
            return None
        if key.startswith(FILE_KEY):
            files[key.removeprefix(FILE_KEY)] = value
    return files


def read_objects(root: Path, specs: Sequence[str]) -> list[bytes | None]:
    """Return each `<rev>:<path>` object's bytes, None when it is absent.

    One `git cat-file --batch` serves every spec, so a check stays fast.
    """

    if not specs:
        return []
    if any("\n" in spec for spec in specs):
        msg = "object specs must not contain newlines"
        raise ValueError(msg)
    result = subprocess.run(  # noqa: S603 - Fixed git argv, no shell.
        ["git", "-C", str(root), "cat-file", "--batch"],  # noqa: S607 - git is on PATH.
        input="".join(f"{spec}\n" for spec in specs).encode(),
        capture_output=True,
        check=True,
    )
    out, at = result.stdout, 0
    found: list[bytes | None] = []
    for _ in specs:
        end = out.index(b"\n", at)
        header = out[at:end]
        at = end + 1
        # `<spec> missing` or `<spec> ambiguous`; a spec may hold spaces.
        if header.endswith((b" missing", b" ambiguous")):
            found.append(None)
            continue
        size = int(header.rsplit(b" ", 1)[1])
        found.append(out[at : at + size])
        at += size + 1
    return found


Reader = Callable[[Sequence[str]], list[bytes | None]]


def check(read: Reader) -> list[str]:
    """Describe each locked file whose bytes `read` returns off its hash.

    `read` maps repo-relative paths to their bytes, None when absent.
    """

    (lock,) = read([LOCK_PATH])
    if lock is None:
        return []
    files = locked_files(lock)
    if files is None:
        return [f"{LOCK_PATH} (malformed)"]
    paths = sorted(files)
    found = []
    for path, data in zip(paths, read(paths), strict=True):
        if data is None:
            found.append(f"{path} (missing)")
        elif digest(data) != files[path]:
            found.append(f"{path} (edited)")
    return found


def commit_reader(root: Path) -> Reader:
    """Read what the commit lefthook is running for will hold."""

    names = git_queries.run_git(root, "diff", "--cached", "--name-only", "-z")
    staged = set((names or "").split("\0")) - {""}

    def read(paths: Sequence[str]) -> list[bytes | None]:
        indexed = read_objects(root, [f":{path}" for path in paths])
        return [
            _working(root / path) if path in staged else blob
            for path, blob in zip(paths, indexed, strict=True)
        ]

    return read


def _working(path: Path) -> bytes | None:
    """Return a working-tree file's bytes; None when absent or a symlink."""

    if path.is_symlink() or not path.is_file():
        return None
    return path.read_bytes()


def tree_reader(root: Path, commit: str) -> Reader:
    def read(paths: Sequence[str]) -> list[bytes | None]:
        return read_objects(root, [f"{commit}:{path}" for path in paths])

    return read


def push_drift(root: Path, lines: Iterable[str]) -> list[str]:
    """Check each pushed tip; a deletion sends nothing."""

    tips = dict.fromkeys(
        parts[1]
        for parts in (line.split() for line in lines)
        if len(parts) == 4 and not git_queries.is_null_sha(parts[1])
    )
    return [
        f"{tip[:12]}: {item}"
        for tip in tips
        for item in check(tree_reader(root, tip))
    ]


def main(argv: Sequence[str], stdin: Iterable[str]) -> int:
    root = git_queries.repo_root(Path.cwd())
    if root is None:
        return 0
    hook = argv[0] if argv else ""
    if hook == "pre-commit":
        found = check(commit_reader(root))
    elif hook == "pre-push":
        found = push_drift(root, stdin)
    else:
        print("usage: kit_drift.py pre-commit | pre-push", file=sys.stderr)
        return 2
    if not found:
        return 0
    listed = "".join(f"\n  {item}" for item in found)
    print(
        f"kit drift: installed kit files differ from {LOCK_PATH}:{listed}\n"
        f"{FIX}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], sys.stdin))
