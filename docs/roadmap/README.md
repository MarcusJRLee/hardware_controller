# Roadmap

```bash
uv run --no-project python .mjrlee_repo_setup/tools/roadmap.py        # List, writes index.md.
uv run --no-project python .mjrlee_repo_setup/tools/roadmap.py claim  # Claim the top agent item.
```

Committed work is one `<slug>.md` per outcome here; the generated, gitignored
`index.md` orders it. Ideas below have no commitment yet.

## Ideas

| Idea | Trigger |
| --- | --- |
| Remote providers for Local AI or speech. | A new privacy decision approves a remote-capable provider ([Local-only boundary](../decisions/local_only_boundary.md)). |
| Build Android, Windows, or Linux apps on the Rust core. | `portable_rust_boundary` lands and a platform is chosen. |
