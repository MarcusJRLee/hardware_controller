"""Git-tracked roadmap: one `docs/roadmap/<slug>.md` per committed outcome.

    uv run --no-project python .mjrlee_repo_setup/tools/roadmap.py [list]
    ... roadmap.py list --offline             # Claims from fetched refs only.
    ... roadmap.py next                       # Top ready, unclaimed agent item.
    ... roadmap.py claim [<slug>]             # Claim it (default: `next`'s).
    ... roadmap.py new <slug> --title T [--priority P2] [--executor human]
                          [--before <slug> | --after <slug>]
    ... roadmap.py move <slug> (--before <slug> | --after <slug>)
    ... roadmap.py check                      # Validate; for the repo gate.

Each item opens with frontmatter in a flat YAML subset (`key: value` or
`key: [a, b]`) holding exactly FIELDS, then `## Outcome` and `## Acceptance`.
An item is ready when `depends_on` is empty: dependencies may name only open
items, so the PR that finishes one deletes its file and its slug from every
`depends_on`. Order is ready first, then priority, then `rank`, a base-36 key
that `new` and `move` write into the one file they touch, so parallel branches
never conflict over order. A pushed `roadmap/<slug>` branch claims an item;
`claim` creates it in `.worktrees/<slug>` from the default branch, installs
dependencies (the pre-push gate needs them), then pushes it create-only, so of
two racing claims exactly one succeeds.

Every command except `check` rewrites the gitignored `docs/roadmap/index.md`
view, which therefore never goes stale in a commit; a run in any worktree also
refreshes the main checkout's. Each row links to the freshest copy: the claim
branch's worktree, else a worktree that edited the file, else the claim branch
on GitHub. Items drafted only in another worktree get a row too.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from collections.abc import Collection, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Final

ROADMAP_DIR: Final = Path("docs/roadmap")
INDEX: Final = "index.md"
NOT_ITEMS: Final = frozenset({"README.md", INDEX})
CLAIM_PREFIX: Final = "roadmap/"
MAX_BYTES: Final = 4096
PRIORITIES: Final = ("P0", "P1", "P2", "P3")
EXECUTORS: Final = ("agent", "human")
FIELDS: Final = ("title", "priority", "rank", "executor", "depends_on", "specs")
LIST_FIELDS: Final = frozenset({"depends_on", "specs"})
SECTIONS: Final = ("## Outcome", "## Acceptance")
DIGITS: Final = "0123456789abcdefghijklmnopqrstuvwxyz"
SLUG: Final = re.compile(r"[a-z0-9]+(?:_[a-z0-9]+)*")
# Never ending in 0 leaves room to insert before any key.
RANK: Final = re.compile(r"[0-9a-z]*[1-9a-z]")
FIELD_LINE: Final = re.compile(r"([a-z_]+):\s*(.*)")

Value = str | tuple[str, ...]


class RoadmapError(Exception):
    """Invalid items or arguments; the message is for a human."""


@dataclass(frozen=True)
class Item:
    slug: str
    title: str
    priority: str
    rank: str
    executor: str
    depends_on: tuple[str, ...]
    specs: tuple[str, ...]

    @property
    def ready(self) -> bool:
        return not self.depends_on

    def sort_key(self) -> tuple[bool, str, str, str]:
        return (not self.ready, self.priority, self.rank, self.slug)


def parse_frontmatter(text: str) -> tuple[dict[str, Value], str]:
    """Split strict flat frontmatter from the body."""

    lines = text.split("\n")
    if lines[0] != "---" or "---" not in lines[1:]:
        raise RoadmapError("must open with `---` frontmatter closed by `---`")
    end = lines.index("---", 1)
    fields: dict[str, Value] = {}
    pending: str | None = None
    for line in lines[1:end]:
        if pending is not None and line.startswith("  - "):
            previous = fields[pending]
            if isinstance(previous, tuple):
                fields[pending] = (*previous, line[4:].strip())
            continue
        match = FIELD_LINE.fullmatch(line)
        if match is None:
            raise RoadmapError(f"unsupported frontmatter line `{line}`")
        key, raw = str(match[1]), str(match[2])
        if key in fields:
            raise RoadmapError(f"duplicate field `{key}`")
        pending = key if raw == "" else None
        if raw == "" or raw == "[]":
            fields[key] = ()
        elif raw.startswith("[") and raw.endswith("]"):
            fields[key] = tuple(v.strip() for v in raw[1:-1].split(","))
        else:
            fields[key] = raw.strip("\"'")
    return fields, "\n".join(lines[end + 1 :])


def _text(
    fields: Mapping[str, Value], key: str, allowed: Sequence[str] = ()
) -> str:
    value = fields[key]
    if not isinstance(value, str) or not value:
        raise RoadmapError(f"`{key}` must be a non-empty string")
    if allowed and value not in allowed:
        raise RoadmapError(
            f"`{key}` must be one of {', '.join(allowed)}; got `{value}`"
        )
    return value


def _list(fields: Mapping[str, Value], key: str) -> tuple[str, ...]:
    value = fields[key]
    if isinstance(value, str):
        raise RoadmapError(f"`{key}` must be a list, e.g. `{key}: []`")
    return value


def parse_item(slug: str, text: str) -> Item:
    if not SLUG.fullmatch(slug):
        raise RoadmapError("file name must be lowercase_with_underscores")
    if len(text.encode()) > MAX_BYTES:
        raise RoadmapError(f"exceeds {MAX_BYTES} bytes; link specs instead")
    fields, body = parse_frontmatter(text)
    missing = [f for f in FIELDS if f not in fields]
    unknown = sorted(set(fields) - set(FIELDS))
    if missing or unknown:
        raise RoadmapError(f"fields missing: {missing}; unknown: {unknown}")
    for key in LIST_FIELDS:
        _list(fields, key)
    rank = _text(fields, "rank")
    if not RANK.fullmatch(rank):
        raise RoadmapError(
            f"`rank` must be base-36 not ending in 0; got `{rank}`"
        )
    for section in SECTIONS:
        if not re.search(rf"^{section}\s*$", body, re.MULTILINE):
            raise RoadmapError(f"missing `{section}` section")
    return Item(
        slug=slug,
        title=_text(fields, "title"),
        priority=_text(fields, "priority", PRIORITIES),
        rank=rank,
        executor=_text(fields, "executor", EXECUTORS),
        depends_on=_list(fields, "depends_on"),
        specs=_list(fields, "specs"),
    )


def load(root: Path) -> tuple[list[Item], list[str]]:
    """Return items in queue order, plus every validation error."""

    items: list[Item] = []
    errors: list[str] = []
    folder = root / ROADMAP_DIR
    paths = sorted(folder.glob("*.md")) if folder.is_dir() else []
    for path in paths:
        if path.name in NOT_ITEMS:
            continue
        try:
            items.append(parse_item(path.stem, path.read_text("utf-8")))
        except RoadmapError as error:
            errors.append(f"{path.relative_to(root)}: {error}")
    slugs = {item.slug for item in items}
    for item in items:
        where = f"{ROADMAP_DIR / item.slug}.md"
        errors.extend(
            f"{where}: depends_on `{dep}` is not another open item; "
            "drop it if finished"
            for dep in item.depends_on
            if dep == item.slug or dep not in slugs
        )
        errors.extend(
            f"{where}: spec `{spec}` does not exist"
            for spec in item.specs
            if not (root / spec).exists()
        )
    errors.extend(_cycles({i.slug: i.depends_on for i in items}))
    return sorted(items, key=Item.sort_key), errors


def _cycles(graph: Mapping[str, Sequence[str]]) -> list[str]:
    errors: list[str] = []
    done: set[str] = set()

    def visit(node: str, path: list[str]) -> None:
        if node in path:
            cycle = [*path[path.index(node) :], node]
            errors.append(f"dependency cycle: {' -> '.join(cycle)}")
            return
        if node in done or node not in graph:
            return
        for dep in graph[node]:
            visit(dep, [*path, node])
        done.add(node)

    for node in sorted(graph):
        visit(node, [])
    return errors


def between(low: str | None, high: str | None) -> str:
    """Return a rank strictly between `low` and `high` (None = unbounded)."""

    if low is not None and high is not None and low >= high:
        raise RoadmapError(f"ranks `{low}` and `{high}` are not ordered")
    low = low or ""
    out = ""
    index = 0
    while True:
        a = DIGITS.index(low[index]) if index < len(low) else 0
        b = (
            DIGITS.index(high[index])
            if high is not None and index < len(high)
            else len(DIGITS)
        )
        if b - a > 1:
            return out + DIGITS[(a + b) // 2]
        out += DIGITS[a]
        if b - a == 1:
            high = None
        index += 1


def placement(
    items: Sequence[Item], priority: str, before: str | None, after: str | None
) -> tuple[str, str]:
    """Return (priority, rank) for a spot in the queue, excluding the mover."""

    anchor = before or after
    if anchor is None:
        ranks = [i.rank for i in items if i.priority == priority]
        return priority, between(max(ranks, default=None), None)
    target = next((i for i in items if i.slug == anchor), None)
    if target is None:
        raise RoadmapError(f"no open item `{anchor}`")
    lane = sorted(
        (i for i in items if i.priority == target.priority),
        key=lambda i: i.rank,
    )
    at = lane.index(target)
    if before:
        low = lane[at - 1].rank if at > 0 else None
        return target.priority, between(low, target.rank)
    high = lane[at + 1].rank if at + 1 < len(lane) else None
    return target.priority, between(target.rank, high)


def _run_git(
    root: Path, *args: str, timeout: float = 15
) -> subprocess.CompletedProcess[str] | None:
    """Run git, or return None when it is missing or hangs."""

    command = ["git", "-C", str(root), *args]
    try:
        # Fixed git argv with no shell; git is resolved from PATH on purpose.
        return subprocess.run(  # noqa: S603
            command,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return None


def _git(root: Path, *args: str, timeout: float = 15) -> str | None:
    """Return git's stdout, or None when git fails, is missing, or hangs."""

    result = _run_git(root, *args, timeout=timeout)
    return (
        result.stdout if result is not None and result.returncode == 0 else None
    )


def _tail(result: subprocess.CompletedProcess[str] | None, limit: int) -> str:
    """The end of a command's output, where its reason for failing is."""

    if result is None:
        return "git is missing or timed out"
    return (result.stderr or result.stdout).strip()[-limit:]


def claims(root: Path, *, offline: bool = False) -> dict[str, str]:
    """Map claimed slugs to their claim branch, from origin when reachable.

    Git hooks pass `offline` so a checkout never waits on the network; a pull
    has just fetched the refs they read.
    """

    remote = (
        None
        if offline
        else _git(root, "ls-remote", "--heads", "origin", f"{CLAIM_PREFIX}*")
    )
    if remote is not None:
        refs = [
            line.split("\t")[1].removeprefix("refs/heads/")
            for line in remote.splitlines()
        ]
    else:
        # Offline or unreachable: use the last fetched view of origin.
        fetched = _git(
            root,
            "for-each-ref",
            "--format=%(refname:lstrip=3)",
            f"refs/remotes/origin/{CLAIM_PREFIX}",
        )
        refs = (fetched or "").split()
    return {
        ref.removeprefix(CLAIM_PREFIX): ref
        for ref in refs
        if ref.startswith(CLAIM_PREFIX)
    }


def next_ready(
    items: Sequence[Item], claimed: Mapping[str, str]
) -> Item | None:
    """Return the top ready, unclaimed agent item in queue order."""

    return next(
        (
            i
            for i in items
            if i.ready and i.executor == "agent" and i.slug not in claimed
        ),
        None,
    )


def _cell(text: str) -> str:
    """Escape a table cell so a `|` in a title cannot split the row."""

    return text.replace("|", r"\|")


# Lockfile → frozen install; the first match wins.
INSTALLS: Final = (
    ("pnpm-lock.yaml", ("pnpm", "install", "--frozen-lockfile")),
    ("bun.lock", ("bun", "install", "--frozen-lockfile")),
    ("package-lock.json", ("npm", "ci")),
)
# Mirrors `WORKTREE_DIR` in `hooks/git_queries.py`, which a module in another
# directory may not import (agents_boundary_test); a test pins the copy.
WORKTREE_DIR: Final = ".worktrees"
# Seconds for git calls that use the network or run hooks.
SLOW_GIT: Final = 300


def install_command(worktree: Path) -> tuple[str, ...] | None:
    return next(
        (argv for lock, argv in INSTALLS if (worktree / lock).is_file()), None
    )


def claim(root: Path, items: Sequence[Item], slug: str | None) -> str:
    """Claim an item: branch and worktree from the default branch, then push.

    Dependencies are installed before the push because the pre-push gate
    checks the worktree. The push is the atomic claim: it wins only if it
    created the branch (porcelain flag `*`). Git reports pushing a commit the
    branch already points at as up to date, without checking a lease, so the
    flag is what catches a racing claim at the same commit; the empty lease
    keeps a claim from moving another claimant's branch. Any failure removes
    the worktree and branch it made.
    """

    claimed = claims(root)
    if slug is None:
        top = next_ready(items, claimed)
        if top is None:
            raise RoadmapError("no ready, unclaimed agent item")
        slug = top.slug
    if slug not in {i.slug for i in items}:
        raise RoadmapError(f"no open item `{slug}`")
    if slug in claimed:
        raise RoadmapError(f"`{slug}` is already claimed by `{claimed[slug]}`")
    worktree = main_checkout(root) / WORKTREE_DIR / slug
    if worktree.exists():
        raise RoadmapError(f"{worktree} already exists")
    if _git(root, "fetch", "--quiet", "origin", timeout=SLOW_GIT) is None:
        raise RoadmapError("`git fetch origin` failed; claims need origin")
    head = _git(root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    if head is None:
        raise RoadmapError(
            "origin/HEAD is unset; run `git remote set-head origin --auto`"
        )
    branch = f"{CLAIM_PREFIX}{slug}"
    if (
        _git(
            root,
            "worktree",
            "add",
            "--quiet",
            "-b",
            branch,
            str(worktree),
            head.strip(),
            timeout=SLOW_GIT,
        )
        is None
    ):
        raise RoadmapError(f"`git worktree add` failed for {worktree}")

    def undo(reason: str) -> RoadmapError:
        _git(root, "worktree", "remove", "--force", str(worktree))
        _git(root, "branch", "-D", branch)
        return RoadmapError(f"{reason}; nothing was claimed")

    argv = install_command(worktree)
    if argv is not None:
        result = subprocess.run(  # noqa: S603 - Fixed installer argv.
            argv, cwd=worktree, capture_output=True, text=True, check=False
        )
        if result.returncode != 0:
            raise undo(f"`{' '.join(argv)}` failed: {_tail(result, 300)}")
    ref = f"refs/heads/{branch}"
    pushed = _run_git(
        worktree,
        "push",
        "--porcelain",
        f"--force-with-lease={ref}:",
        "-u",
        "origin",
        branch,
        timeout=SLOW_GIT,
    )
    created = (
        pushed is not None
        and pushed.returncode == 0
        and any(
            line.split("\t")[:2] == ["*", f"{ref}:{ref}"]
            for line in pushed.stdout.splitlines()
        )
    )
    if not created:
        # Re-read origin: a rejection may be a racing claim or a failed hook.
        winner = claims(root).get(slug)
        if winner is not None:
            raise undo(f"`{winner}` claimed `{slug}` first")
        raise undo(f"pushing `{branch}` failed: {_tail(pushed, 600)}")
    return f"claimed {slug} on {branch}; work in {worktree}"


GITHUB_REMOTE: Final = re.compile(
    r"(?:git@github\.com:|https://github\.com/)([^/]+/[^/]+?)(?:\.git)?/?"
)


@dataclass(frozen=True)
class Copy:
    """One worktree's file for an item: where work on it may be happening."""

    worktree: Path
    branch: str | None
    path: Path


def _worktrees(root: Path) -> list[tuple[Path, str | None]]:
    """Return (path, branch) for every worktree of this repo, main first."""

    listing = _git(root, "worktree", "list", "--porcelain") or ""
    found: list[tuple[Path, str | None]] = []
    for line in listing.splitlines():
        if line.startswith("worktree "):
            found.append((Path(line.removeprefix("worktree ")).resolve(), None))
        elif line.startswith("branch refs/heads/") and found:
            found[-1] = (found[-1][0], line.removeprefix("branch refs/heads/"))
    return found


def main_checkout(root: Path) -> Path:
    common = _git(
        root, "rev-parse", "--path-format=absolute", "--git-common-dir"
    )
    return Path(common.strip()).resolve().parent if common else root.resolve()


def worktree_copies(root: Path) -> dict[str, list[Copy]]:
    """Map each item slug to its files in the other worktrees of this repo."""

    copies: dict[str, list[Copy]] = {}
    for worktree, branch in _worktrees(root):
        if worktree == root.resolve():
            continue
        folder = worktree / ROADMAP_DIR
        for path in sorted(folder.glob("*.md")) if folder.is_dir() else []:
            if path.name not in NOT_ITEMS:
                copies.setdefault(path.stem, []).append(
                    Copy(worktree, branch, path)
                )
    return copies


@dataclass(frozen=True)
class Location:
    """Where an index row points, and what its In progress cell says."""

    link: str
    where: str


def locate(
    root: Path, slugs: Sequence[str], claimed: Mapping[str, str]
) -> dict[str, Location]:
    """Point each item at its freshest copy; unlisted slugs use this checkout's.

    In order: the claim branch's worktree; else the worktree whose file differs
    from this checkout's (most recently edited first), since that is where it
    is being changed; else the claim branch on GitHub, while the fetched branch
    still has the file (the PR that finishes an item deletes it).
    """

    copies = worktree_copies(root)
    remote = GITHUB_REMOTE.fullmatch(
        (_git(root, "remote", "get-url", "origin") or "").strip()
    )
    # git reports resolved paths (e.g. /private/var on macOS); match them.
    folder = root.resolve() / ROADMAP_DIR
    main = main_checkout(root)
    found: dict[str, Location] = {}
    for slug in slugs:
        own = folder / f"{slug}.md"
        text = own.read_text("utf-8") if own.is_file() else None
        branch = claimed.get(slug)
        mine = copies.get(slug, [])
        on_claim = [c for c in mine if branch and c.branch == branch]
        edited = sorted(
            (c for c in mine if c.path.read_text("utf-8") != text),
            key=lambda c: c.path.stat().st_mtime,
            reverse=True,
        )
        pick = (on_claim or edited or [None])[0]
        rel = f"{ROADMAP_DIR.as_posix()}/{slug}.md"
        if pick is not None:
            name = (
                os.path.relpath(pick.worktree, main)
                if pick.worktree != main
                else "main"
            )
            found[slug] = Location(
                Path(os.path.relpath(pick.path, folder)).as_posix(),
                branch or f"edited in {name}",
            )
        elif (
            branch
            and remote
            and _git(root, "cat-file", "-e", f"origin/{branch}:{rel}")
            is not None
        ):
            found[slug] = Location(
                f"https://github.com/{remote[1]}/blob/{branch}/{rel}", branch
            )
        elif branch:
            found[slug] = Location(f"{slug}.md", branch)
    return found


def new_elsewhere(root: Path, known: Collection[str]) -> list[Item]:
    """Items that exist only in another worktree: drafts not yet merged here."""

    drafts: list[Item] = []
    for slug, copies in worktree_copies(root).items():
        if slug in known:
            continue
        newest = max(copies, key=lambda c: c.path.stat().st_mtime)
        try:
            drafts.append(parse_item(slug, newest.path.read_text("utf-8")))
        except RoadmapError:
            continue
    return drafts


def render_index(
    items: Sequence[Item],
    locations: Mapping[str, Location],
) -> str:
    rows = []
    for n, i in enumerate(items, start=1):
        at = locations.get(i.slug, Location(f"{i.slug}.md", ""))
        rows.append(
            f"| {n} | [{_cell(i.title)}]({at.link}) | {i.priority} | {i.executor} | "
            f"{_cell(at.where)} | {', '.join(i.depends_on)} |"
        )
    return "\n".join(
        [
            "# Roadmap",
            "",
            "Generated by `roadmap.py` and gitignored; edit the items instead.",
            "",
            "| # | Item | Priority | Executor | In progress | Waiting on |",
            "| - | ---- | -------- | -------- | ----------- | ---------- |",
            *rows,
            "",
        ]
    )


def write_index(root: Path, *, offline: bool) -> str:
    """Render and write `root`'s index, drafts from other worktrees included."""

    items, _errors = load(root)
    claimed = claims(root, offline=offline)
    drafts = new_elsewhere(root, {i.slug for i in items})
    every = sorted([*items, *drafts], key=Item.sort_key)
    index = render_index(every, locate(root, [i.slug for i in every], claimed))
    if every or (root / ROADMAP_DIR).is_dir():
        (root / ROADMAP_DIR / INDEX).write_text(index, "utf-8")
    return index


def item_text(title: str, priority: str, rank: str, executor: str) -> str:
    return (
        f"---\ntitle: {title}\npriority: {priority}\nrank: {rank}\n"
        f"executor: {executor}\ndepends_on: []\nspecs: []\n---\n\n"
        "## Outcome\n\nTODO: the observable result, in one or two sentences.\n\n"
        "## Acceptance\n\n- TODO: a command that passes, or `Human:` and what they check.\n"
    )


def set_rank(path: Path, priority: str, rank: str) -> None:
    text = path.read_text("utf-8")
    text = re.sub(r"(?m)^priority: .*$", f"priority: {priority}", text, count=1)
    text = re.sub(r"(?m)^rank: .*$", f"rank: {rank}", text, count=1)
    path.write_text(text, "utf-8")


def _require_valid(errors: Sequence[str]) -> None:
    if errors:
        raise RoadmapError(
            "\n".join(
                [*errors, "fix these first; `roadmap.py check` lists them"]
            )
        )


def run(root: Path, argv: Sequence[str]) -> str:
    """Execute a command and return its output; raises RoadmapError."""

    parser = argparse.ArgumentParser(
        prog="roadmap.py", description=__doc__.splitlines()[0]
    )
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("list").add_argument("--offline", action="store_true")
    sub.add_parser("next")
    sub.add_parser("claim").add_argument("slug", nargs="?")
    sub.add_parser("check")
    for name in ("new", "move"):
        p = sub.add_parser(name)
        p.add_argument("slug")
        where = p.add_mutually_exclusive_group(required=name == "move")
        where.add_argument("--before")
        where.add_argument("--after")
        if name == "new":
            p.add_argument("--title", required=True)
            p.add_argument("--priority", choices=PRIORITIES, default="P2")
            p.add_argument("--executor", choices=EXECUTORS, default="agent")
    args = parser.parse_args(argv)
    command = str(args.command or "list")
    items, errors = load(root)
    if command == "check":
        _require_valid(errors)
        return f"{len(items)} roadmap item(s) valid"
    _require_valid(errors)
    output = ""
    if command in ("new", "move"):
        slug = str(args.slug)
        path = root / ROADMAP_DIR / f"{slug}.md"
        before = str(args.before) if args.before else None
        after = str(args.after) if args.after else None
        others = [i for i in items if i.slug != slug]
        if command == "new":
            if path.exists() or not SLUG.fullmatch(slug):
                raise RoadmapError(
                    f"`{slug}` exists or is not lowercase_with_underscores"
                )
            priority, rank = placement(
                others, str(args.priority), before, after
            )
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                item_text(str(args.title), priority, rank, str(args.executor)),
                "utf-8",
            )
            output = f"created {path.relative_to(root)}; fill in Outcome and Acceptance"
        else:
            if not path.is_file():
                raise RoadmapError(f"no open item `{slug}`")
            priority, rank = placement(others, "", before, after)
            set_rank(path, priority, rank)
            output = f"moved {slug} to {priority} rank {rank}"
        items, errors = load(root)
    if command == "claim":
        output = claim(root, items, str(args.slug) if args.slug else None)
    offline = bool(getattr(args, "offline", False))
    claimed = claims(root, offline=offline)
    index = write_index(root, offline=offline)
    # The main checkout's view is the one people open; refresh it from any
    # worktree, so work there shows up without a pull in main.
    main = main_checkout(root)
    if main != root.resolve() and (main / ROADMAP_DIR).is_dir():
        write_index(main, offline=offline)
    if command == "next":
        top = next_ready(items, claimed)
        if top is None:
            return "no ready, unclaimed agent item"
        return (
            f"{ROADMAP_DIR / top.slug}.md  {top.priority}  {top.title}\n"
            f"claim: roadmap.py claim {top.slug}"
        )
    if command == "list":
        output = index
    return output


def repo_root() -> Path:
    top = _git(Path.cwd(), "rev-parse", "--show-toplevel")
    return Path(top.strip()) if top else Path.cwd()


def main(argv: Sequence[str]) -> int:
    root = repo_root()
    try:
        print(run(root, argv))
    except RoadmapError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
