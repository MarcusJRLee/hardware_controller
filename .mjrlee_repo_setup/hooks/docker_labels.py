"""Labels every Docker resource a repo creates must carry, and the repo gate.

Docker labels travel with the resource, so `docker inspect` answers who made
it, why, and whether it may be deleted, without anyone having to remember:

| Label             | Value                                              |
| ----------------- | -------------------------------------------------- |
| `mjrlee.owner`    | Repo and module that creates it, e.g. `civic/api`. |
| `mjrlee.purpose`  | One sentence on what it is for.                    |
| `mjrlee.lifetime` | A key of LIFETIMES.                                |

The gate checks every git-tracked compose file: each service needs `labels`
and each service that builds needs `build.labels`. Named volume labels are
optional but checked when present: Docker cannot relabel a volume, and Compose
offers to delete and recreate an existing volume whose labels change, so
requiring them would put existing data one keystroke from loss. Networks are
exempt; compose creates and removes them with the stack. The audit tool
attributes unlabeled volumes and networks by compose project. Run from the repo
root (exit 1 on any violation, 2 when docker is needed but missing):

    uv run --no-project python .mjrlee_repo_setup/hooks/docker_labels.py
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Final

import git_queries

OWNER: Final = "mjrlee.owner"
PURPOSE: Final = "mjrlee.purpose"
LIFETIME: Final = "mjrlee.lifetime"
KEYS: Final = (OWNER, PURPOSE, LIFETIME)
# Lifetime → when the resource may be deleted. Order is least to most durable.
LIFETIMES: Final = {
    "ephemeral": "any time it is unused",
    "cache": "when reclaiming space; it can be rebuilt or re-pulled",
    "persistent": "only with the owner's approval; it holds state",
}
GUIDANCE: Final = (
    f"Docker labels: give every resource {', '.join(KEYS)} "
    f"({LIFETIME} one of {', '.join(LIFETIMES)}); see AGENTS.md"
)
_COMPOSE_FILE: Final = re.compile(
    r"(?:^|/)(?:docker-)?compose(?:\.[\w.-]+)?\.ya?ml$"
)


def label_problems(labels: Mapping[str, str]) -> tuple[str, ...]:
    """Return what is missing or invalid in one resource's labels."""

    problems = [f"missing {key}" for key in KEYS if not labels.get(key)]
    lifetime = labels.get(LIFETIME)
    if lifetime and lifetime not in LIFETIMES:
        problems.append(
            f"{LIFETIME}={lifetime} is not one of {list(LIFETIMES)}"
        )
    return tuple(problems)


def _str_map(value: object) -> dict[str, str]:
    """Return a compose `labels` mapping; anything else counts as empty."""

    if not isinstance(value, dict):
        return {}
    return {str(k): str(v) for k, v in value.items() if v is not None}


def _dict(value: object) -> dict[str, object]:
    return (
        {str(k): v for k, v in value.items()} if isinstance(value, dict) else {}
    )


def compose_problems(config: Mapping[str, object]) -> tuple[str, ...]:
    """Return label problems in a normalized (`docker compose config`) file."""

    problems: list[str] = []

    def check(where: str, labels: object) -> None:
        problems.extend(
            f"{where}: {p}" for p in label_problems(_str_map(labels))
        )

    for name, service in _dict(config.get("services")).items():
        spec = _dict(service)
        check(f"service {name}", spec.get("labels"))
        if "build" in spec:
            check(f"service {name} build", _dict(spec["build"]).get("labels"))
    for name, volume in _dict(config.get("volumes")).items():
        labels = _dict(volume).get("labels")
        if labels:
            check(f"volume {name}", labels)
    return tuple(problems)


def compose_files(root: Path) -> tuple[Path, ...]:
    listed = git_queries.run_git(root, "ls-files", "-z") or ""
    return tuple(
        root / rel for rel in listed.split("\0") if _COMPOSE_FILE.search(rel)
    )


def normalized_compose(path: Path) -> dict[str, object]:
    """Return compose's own normalization of `path`.

    Compose resolves anchors, `extends`, and list-form labels, so nothing here
    parses YAML. Interpolation and env files are skipped: labels must not
    depend on a machine's environment.
    """

    result = subprocess.run(  # noqa: S603 - Fixed argv; path is git-tracked.
        [  # noqa: S607 - docker is on PATH.
            "docker",
            "compose",
            "--file",
            str(path),
            "config",
            "--no-interpolate",
            "--no-path-resolution",
            "--no-env-resolution",
            "--format",
            "json",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        msg = f"docker compose config failed: {result.stderr.strip()}"
        raise ValueError(msg)
    return _dict(json.loads(result.stdout))


def check(root: Path) -> tuple[str, ...]:
    problems: list[str] = []
    for path in compose_files(root):
        rel = path.relative_to(root)
        try:
            found = compose_problems(normalized_compose(path))
        except ValueError as error:
            found = (str(error),)
        problems.extend(f"{rel}: {p}" for p in found)
    return tuple(problems)


def main() -> int:
    root = git_queries.repo_root(Path.cwd())
    if root is None:
        print("error: not inside a git repo", file=sys.stderr)
        return 2
    if compose_files(root) and shutil.which("docker") is None:
        print("error: compose files need the docker CLI", file=sys.stderr)
        return 2
    problems = check(root)
    if problems:
        print(f"{GUIDANCE}:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
