# Agent Guidelines (blog)

This repo uses **bd (beads)** for all work tracking. Do not create markdown TODO lists or other parallel trackers.

## Beads

- Primary guide: `.beads/BD_GUIDE.md` (auto-generated; do not edit manually).
- Check ready work: `bd ready --json`
- Claim work: `bd update <id> --status in_progress --json`
- Close work: `bd close <id> --reason "Done" --json`
- Keep the daemon running: `bd daemon --start --auto-commit --auto-push --json`
- Sync branch must be `beads-metadata`: `bd config get sync.branch`

