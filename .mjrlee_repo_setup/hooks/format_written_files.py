"""PostToolUse hook: format files the agent just wrote with the repo formatter.

Contract with the host repo: its package.json may define `format:file:*`
scripts that accept one file path, so tool pins stay in one place; file types
without a script are skipped. Scripts run directly
with `node_modules/.bin` on PATH; `pnpm run` adds ~280 ms per call. Failures
never block; they are reported to the model.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Final

import git_queries
from hook_event import context_output, parse_event

_SCRIPT_BY_SUFFIX: Final[dict[str, str]] = {
    ".md": "format:file:prettier",
    ".yml": "format:file:prettier",
    ".yaml": "format:file:prettier",
    ".js": "format:file:biome",
    ".jsx": "format:file:biome",
    ".ts": "format:file:biome",
    ".tsx": "format:file:biome",
    ".json": "format:file:biome",
    ".jsonc": "format:file:biome",
    ".py": "format:file:ruff",
    ".sh": "format:file:shfmt",
}


def formatter_script(path: Path) -> str | None:
    return _SCRIPT_BY_SUFFIX.get(path.suffix)


def load_scripts(root: Path) -> dict[str, str]:
    """Return package.json scripts, or {} when absent or malformed."""

    try:
        package: object = json.loads(
            (root / "package.json").read_text(encoding="utf-8")
        )
    except (OSError, ValueError):
        return {}
    scripts = package.get("scripts") if isinstance(package, dict) else None
    if not isinstance(scripts, dict):
        return {}
    return {
        str(name): body
        for name, body in scripts.items()
        if isinstance(body, str)
    }


def format_file(
    root: Path, path: Path, script: str, scripts: dict[str, str]
) -> str | None:
    """Run `script` on `path`; return an error summary, or None on success."""

    body = scripts[script]
    env = {
        **os.environ,
        "PATH": f"{root / 'node_modules' / '.bin'}{os.pathsep}"
        + os.environ.get("PATH", ""),
    }
    try:
        # The script body is repo-owned config; the path is passed as $1.
        result = subprocess.run(  # noqa: S603 - Repo-owned script, path as argv.
            ["/bin/sh", "-c", f'{body} "$1"', "sh", str(path)],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as error:
        return f"{path.name}: {error}"
    if result.returncode == 0:
        return None
    detail = (result.stderr or result.stdout).strip().splitlines()[-5:]
    return f"{path.name} ({script}) failed:\n" + "\n".join(detail)


def main() -> int:
    event = parse_event(sys.stdin.read())
    root = git_queries.repo_root(event.cwd)
    if root is None:
        return 0
    scripts = load_scripts(root)
    errors: list[str] = []
    for path in event.written_paths:
        script = formatter_script(path) or ""
        if script in scripts and path.is_file() and path.is_relative_to(root):
            error = format_file(root, path, script, scripts)
            if error:
                errors.append(error)
    if errors:
        print(context_output(event, "Auto-format:\n" + "\n\n".join(errors)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
