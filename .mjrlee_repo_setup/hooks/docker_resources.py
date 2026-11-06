"""Audit and prune this machine's Docker resources by their mjrlee labels.

    uv run --no-project python .mjrlee_repo_setup/hooks/docker_resources.py
    ... docker_resources.py audit             # Owner, purpose, lifetime of all.
    ... docker_resources.py prune             # Plan: unused `ephemeral` ones.
    ... docker_resources.py prune --cache     # Also unused `cache`, build cache.
    ... docker_resources.py prune --yes       # Delete what the plan lists.

Labels come first (see docker_labels.py). Where a resource lacks them, the
audit infers what it can and marks it: the owner from compose or Supabase CLI
labels, or from the container using it; `cache` for any image, since every
image can be rebuilt or re-pulled. Prune deletes only by lifetime, explicit
or inferred, and never anything in use: a running container, or an image,
volume, or network that any remaining container references.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections.abc import Collection, Mapping, Sequence
from dataclasses import dataclass, replace
from enum import Enum
from pathlib import Path
from typing import Final

import docker_labels as dl

COMPOSE_PROJECT: Final = "com.docker.compose.project"
COMPOSE_DIR: Final = "com.docker.compose.project.working_dir"
SUPABASE_PROJECT: Final = "com.supabase.cli.project"
BUILTIN_NETWORKS: Final = frozenset({"bridge", "host", "none"})
UNKNOWN: Final = "?"
PURPOSE_WIDTH: Final = 60


class Kind(Enum):
    CONTAINER = "container"
    IMAGE = "image"
    VOLUME = "volume"
    NETWORK = "network"


@dataclass(frozen=True)
class Resource:
    """One Docker object, reduced to what attribution and pruning need."""

    kind: Kind
    id: str
    name: str
    labels: Mapping[str, str]
    # Containers only: whether it runs, and what it references.
    running: bool = False
    image_id: str = ""
    volumes: tuple[str, ...] = ()
    networks: tuple[str, ...] = ()
    # Images only: tags to delete by.
    tags: tuple[str, ...] = ()


@dataclass(frozen=True)
class Attribution:
    """Who owns a resource and when it may go; None where nothing says."""

    owner: str | None
    purpose: str | None
    lifetime: str | None
    # How owner and lifetime were found, when not from mjrlee labels.
    owner_from: str | None = None
    lifetime_from: str | None = None


class DockerError(Exception):
    """A docker command failed; the message is for a human."""


# --- Docker transport. -------------------------------------------------------


def _docker(*args: str) -> str:
    try:
        result = subprocess.run(  # noqa: S603 - Fixed argv from this module.
            ["docker", *args],  # noqa: S607 - docker is on PATH.
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as error:
        msg = "the docker CLI is not on PATH"
        raise DockerError(msg) from error
    if result.returncode != 0:
        msg = f"docker {' '.join(args)}: {result.stderr.strip()}"
        raise DockerError(msg)
    return result.stdout


def _inspect(kind: str, ls: Sequence[str]) -> list[dict[str, object]]:
    ids = sorted(set(_docker(*ls).split()))
    if not ids:
        return []
    return [
        _dict(item)
        for item in _list(json.loads(_docker(kind, "inspect", *ids)))
    ]


def _dict(value: object) -> dict[str, object]:
    return (
        {str(k): v for k, v in value.items()} if isinstance(value, dict) else {}
    )


def _list(value: object) -> list[object]:
    return list(value) if isinstance(value, list) else []


def _str(value: object) -> str:
    return value if isinstance(value, str) else ""


def _labels(value: object) -> dict[str, str]:
    return {k: v for k, v in _dict(value).items() if isinstance(v, str)}


def parse_container(raw: Mapping[str, object]) -> Resource:
    mounts = (_dict(m) for m in _list(raw.get("Mounts")))
    networks = _dict(_dict(raw.get("NetworkSettings")).get("Networks"))
    return Resource(
        kind=Kind.CONTAINER,
        id=_str(raw.get("Id")),
        name=_str(raw.get("Name")).lstrip("/"),
        labels=_labels(_dict(raw.get("Config")).get("Labels")),
        running=_dict(raw.get("State")).get("Running") is True,
        image_id=_str(raw.get("Image")),
        volumes=tuple(
            _str(m.get("Name")) for m in mounts if m.get("Type") == "volume"
        ),
        networks=tuple(networks),
    )


def parse_image(raw: Mapping[str, object]) -> Resource:
    tags = tuple(_str(t) for t in _list(raw.get("RepoTags")) if _str(t))
    image_id = _str(raw.get("Id"))
    return Resource(
        kind=Kind.IMAGE,
        id=image_id,
        name=tags[0] if tags else image_id.removeprefix("sha256:")[:12],
        labels=_labels(_dict(raw.get("Config")).get("Labels")),
        tags=tags,
    )


def parse_named(kind: Kind, raw: Mapping[str, object]) -> Resource:
    """Parse a volume or network, which share Name and Labels."""

    name = _str(raw.get("Name"))
    return Resource(
        kind=kind,
        id=_str(raw.get("Id")) or name,
        name=name,
        labels=_labels(raw.get("Labels")),
    )


def collect() -> tuple[Resource, ...]:
    containers = _inspect("container", ("ps", "-aq", "--no-trunc"))
    images = _inspect("image", ("image", "ls", "-q", "--no-trunc"))
    volumes = _inspect("volume", ("volume", "ls", "-q"))
    networks = _inspect("network", ("network", "ls", "-q", "--no-trunc"))
    return (
        *(parse_container(c) for c in containers),
        *(parse_image(i) for i in images),
        *(parse_named(Kind.VOLUME, v) for v in volumes),
        *(
            r
            for r in (parse_named(Kind.NETWORK, n) for n in networks)
            if r.name not in BUILTIN_NETWORKS
        ),
    )


# --- Attribution and pruning. ------------------------------------------------


def _users(
    resource: Resource, containers: Collection[Resource]
) -> list[Resource]:
    """Return the containers that reference `resource`."""

    match resource.kind:
        case Kind.CONTAINER:
            return []
        case Kind.IMAGE:
            return [c for c in containers if c.image_id == resource.id]
        case Kind.VOLUME:
            return [c for c in containers if resource.name in c.volumes]
        case Kind.NETWORK:
            return [c for c in containers if resource.name in c.networks]


def module_name(directory: Path) -> str:
    """Name a directory `repo/module`, the form `mjrlee.owner` uses."""

    for root in (directory, *directory.parents):
        if (root / ".git").exists():
            rel = directory.relative_to(root).as_posix()
            return root.name if rel == "." else f"{root.name}/{rel}"
    return str(directory).replace(str(Path.home()), "~", 1)


def _tool_owner(
    resource: Resource, containers: Collection[Resource]
) -> tuple[str, str] | None:
    """Return (owner, source) from labels compose or the Supabase CLI set."""

    project = resource.labels.get(COMPOSE_PROJECT)
    directory = resource.labels.get(COMPOSE_DIR) or next(
        (
            c.labels[COMPOSE_DIR]
            for c in containers
            if project
            and c.labels.get(COMPOSE_PROJECT) == project
            and COMPOSE_DIR in c.labels
        ),
        None,
    )
    if directory:
        return module_name(Path(directory)), "compose"
    supabase = resource.labels.get(SUPABASE_PROJECT)
    if supabase:
        return supabase, "supabase CLI"
    if project:
        return project, "compose project"
    return None


def attribute(
    resource: Resource, containers: Collection[Resource]
) -> Attribution:
    labels = resource.labels
    found = Attribution(
        owner=labels.get(dl.OWNER) or None,
        purpose=labels.get(dl.PURPOSE) or None,
        lifetime=labels.get(dl.LIFETIME) or None,
    )
    if found.owner is None:
        tool = _tool_owner(resource, containers)
        if tool is not None:
            found = replace(found, owner=tool[0], owner_from=tool[1])
        else:
            user = next(
                (
                    (attribute(c, containers).owner, c.name)
                    for c in _users(resource, containers)
                ),
                None,
            )
            if user is not None and user[0] is not None:
                found = replace(
                    found, owner=user[0], owner_from=f"used by {user[1]}"
                )
    if found.lifetime is None and resource.kind is Kind.IMAGE:
        found = replace(found, lifetime="cache", lifetime_from="inferred")
    return found


@dataclass(frozen=True)
class Deletion:
    resource: Resource
    lifetime: str


def prune_plan(
    resources: Sequence[Resource], *, include_cache: bool
) -> tuple[Deletion, ...]:
    """Return what to delete, containers first, so the rest can be unused."""

    lifetimes = {"ephemeral", "cache"} if include_cache else {"ephemeral"}
    containers = [r for r in resources if r.kind is Kind.CONTAINER]
    lifetime = {r.id: attribute(r, containers).lifetime for r in resources}
    doomed = [
        c for c in containers if not c.running and lifetime[c.id] in lifetimes
    ]
    remaining = [c for c in containers if c not in doomed]
    others = [
        r
        for r in resources
        if r.kind is not Kind.CONTAINER
        and lifetime[r.id] in lifetimes
        and not _users(r, remaining)
    ]
    return tuple(
        Deletion(r, lifetime[r.id] or UNKNOWN) for r in (*doomed, *others)
    )


def delete(deletion: Deletion) -> None:
    resource = deletion.resource
    # An image with several tags is deleted by tag; by id docker refuses.
    refs = (
        resource.tags
        if resource.kind is Kind.IMAGE and resource.tags
        else (resource.id,)
    )
    _docker(resource.kind.value, "rm", *refs)


# --- Rendering and CLI. ------------------------------------------------------


def _cell(value: str | None, source: str | None) -> str:
    if value is None:
        return UNKNOWN
    return f"{value} ({source})" if source else value


def _clip(text: str) -> str:
    return (
        text if len(text) <= PURPOSE_WIDTH else f"{text[: PURPOSE_WIDTH - 1]}…"
    )


def render_table(rows: Sequence[Sequence[str]]) -> str:
    widths = [max(len(row[i]) for row in rows) for i in range(len(rows[0]))]
    return "\n".join(
        "  ".join(
            cell.ljust(w) for cell, w in zip(row, widths, strict=True)
        ).rstrip()
        for row in rows
    )


def audit_report(resources: Sequence[Resource]) -> str:
    containers = [r for r in resources if r.kind is Kind.CONTAINER]
    entries = sorted(
        ((r, attribute(r, containers)) for r in resources),
        key=lambda e: (
            e[1].owner is None,
            e[1].owner or "",
            e[0].kind.value,
            e[0].name,
        ),
    )
    rows = [("OWNER", "KIND", "NAME", "LIFETIME", "IN USE", "PURPOSE")]
    rows.extend(
        (
            _cell(a.owner, a.owner_from),
            r.kind.value,
            r.name,
            _cell(a.lifetime, a.lifetime_from),
            "yes" if r.running or _users(r, containers) else "no",
            _clip(a.purpose or UNKNOWN),
        )
        for r, a in entries
    )
    unlabeled = sum(1 for r in resources if dl.label_problems(r.labels))
    lines = [render_table(rows)] if entries else ["No Docker resources."]
    if unlabeled:
        lines.append(
            f"\n{unlabeled} of {len(resources)} lack mjrlee labels; "
            "(…) marks inferred values. Label resources where they are "
            "created (see AGENTS.md)."
        )
    return "\n".join(lines)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Audit and prune Docker resources by mjrlee labels."
    )
    commands = parser.add_subparsers(dest="command")
    commands.add_parser("audit", help="List every resource's attribution.")
    prune = commands.add_parser("prune", help="Delete unused, clearable ones.")
    prune.add_argument(
        "--cache", action="store_true", help="Include `cache` and build cache."
    )
    prune.add_argument(
        "--yes", action="store_true", help="Delete; without it, only plan."
    )
    args = parser.parse_args(argv)
    try:
        resources = collect()
        if args.command != "prune":
            print(audit_report(resources))
            return 0
        plan = prune_plan(resources, include_cache=args.cache)
        for d in plan:
            print(f"{d.resource.kind.value} {d.resource.name} ({d.lifetime})")
        if args.cache:
            print("build cache (cache)")
        if not args.yes:
            print("\nPlan only; re-run with --yes to delete.")
            return 0
        for d in plan:
            delete(d)
        if args.cache:
            _docker("builder", "prune", "--all", "--force")
    except DockerError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
