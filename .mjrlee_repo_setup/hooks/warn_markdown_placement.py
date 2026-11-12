"""PostToolUse hook: warn when the agent writes new Markdown outside its place.

The rule lives in `markdown_placement`. Only files new to git are checked, so
editing an existing file never warns; the repo-wide check catches the rest.

test_exempt: thin hook over markdown_placement, which its test covers.
"""

from __future__ import annotations

import sys

import git_queries
from hook_event import context_output, parse_event
from markdown_placement import GUIDANCE, load_policy, misplaced


def main() -> int:
    event = parse_event(sys.stdin.read())
    root = git_queries.repo_root(event.cwd)
    if root is None:
        return 0
    new_paths = [
        path
        for path in event.written_paths
        if path.is_relative_to(root)
        and not git_queries.is_known_path(root, path)
    ]
    rejected = misplaced(root, new_paths, load_policy(root))
    if rejected:
        print(context_output(event, f"{GUIDANCE}: " + ", ".join(rejected)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
