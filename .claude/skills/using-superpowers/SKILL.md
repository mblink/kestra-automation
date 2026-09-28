---
name: using-superpowers
description: Use when starting any task in the kestra-automation repo to determine which skills apply. Routes task types to the repo's skills and slash commands.
---

# Using Superpowers

<EXTREMELY-IMPORTANT>
If you think there is even a 1% chance a skill might apply to what you are doing, invoke it.

IF A SKILL APPLIES TO YOUR TASK, YOU MUST USE IT — before any response or action, and before asking
clarifying questions. Routing rows list several skills; read all of them before the first edit.
</EXTREMELY-IMPORTANT>

Flow layout, task anatomy and the test-enforced pitfalls are in `CLAUDE.md`; read it before writing or editing a flow.

## Skill routing table

| Task type | Skills to invoke |
| --------- | ---------------- |
| A production flow failed, a `kestra.prod.bondlink.org` URL, or what revision is actually deployed | `kestra` |
| Finding logs or backups in S3; writing or changing anything that globs, lists or deletes under `weblogs/`, `syslogs/`, `backups/mysql/` | `s3-backup-layout`, `scoped-aws-credentials` |
| Reaching AWS at all — `make test-integration`, a describe, listing a bucket, any investigation | `scoped-aws-credentials` |
| A CI build failed, a PR build never started or hangs, or editing `.woodpecker.yml` | `woodpecker` |
| Watching a PR's build to completion | `woodpecker` (`watch-pr-build.sh`) |

## Slash commands

| Command | Purpose |
| ------- | ------- |
| `/commit` | Review, verify (`make test`, `make lint`), commit (no approval prompt); refuses to commit on `main` |
| `/pr` | Draft PR against `main`: push, `gh pr create --draft`, watch the Woodpecker build |

For a correctness pass over a diff, use the built-in `/code-review`.
