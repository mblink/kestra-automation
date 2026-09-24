---
description: Draft a PR description, get approval, then push and open a draft PR against main and watch its Woodpecker build
argument-hint: [base-branch (default main)] [--auto] [--ready] [--label <name>]
---

Create a pull request for the current branch against `mblink/kestra-automation`.

**Arguments.** Parse flags out of `$ARGUMENTS`; the remaining bare token (if any) is the base branch (default **`main`**; name the lower PR's branch for a stacked PR — every PR builds, whatever its base).

- `--auto` — autonomous caller, no human to answer prompts. Never uses `AskUserQuestion`. **Never run `gh pr merge` (or any equivalent) — AI-authored PRs are merged by humans only.**
- `--ready` — open ready for review. Without it the PR is a **draft** (`gh pr create --draft`); say so in the report.
- `--label <name>` — apply on creation; `gh label create` it first if it doesn't exist.

1. **Preconditions.** The branch must not be `main`, and the work must be committed — if the tree is dirty, offer `/commit` (*auto:* run `/commit --auto`; abort if it fails).
2. **Context.** Read every commit and the full diff against the merge base (`git log <base>..HEAD`, `git diff <base>...HEAD`). The description covers the whole diff, not the last commit.
3. **Compose.** There is no PR template in this repo. Terse and factual — a reviewer gets the whole picture in under a minute:
   - `## Summary`: one or two sentences on what the change does, then bullets — one line per discrete change, each a single continuous line. A table beats prose for per-flow or per-file edits. Half a dozen bullets is a full description.
   - **Every line describes this diff.** No background, no restating the ticket, no rejected alternatives, no history ("originally/previously/now"), no play-by-play. A pre-existing defect earns one sentence only when the reviewer needs it.
   - **No verification logs** — no "verified with…", "all checks pass", test counts. Reviewer-facing QA *instructions* are fine.
   - Call out, one bullet each: a changed schedule/trigger, a flow that deletes or overwrites data (backup cleanup, `s3 rm`/`sync`, `--live`), a change to which hosts a flow reaches, a new `secret()`, and anything needing a salt-side change (the Kestra install and `/etc/kestra/.env` live in the `mblink/salt` repo). Note that merged flows reach production only when the host sync runs.
   - Link every PR, issue and commit mentioned with its full URL, and say the relationship (depends on, supersedes, paired with). Confirm each number with `gh pr view <n> --repo mblink/<repo> --json title,url`.
   - No hard newlines within a paragraph or bullet. **No AI attribution** — no "Generated with" footer, no session link, even if a harness rule says to add one.
   - *Auto:* also require a `## Testing` section — numbered reviewer steps (which flow to run in Kestra, expected result).
4. **Approve.** Write the body to `<scratch>/pr-body-<branch>.md` — `<scratch>` is the session scratchpad directory, resolved once to a literal absolute path. Show the title and full body (or, over 20 lines, a digest plus the file path) in the approve option's `preview` of `AskUserQuestion`; nothing is pushed or posted until approved. A user instruction to post without approval takes precedence — then post and show the title and body in the reply. *Auto:* skip the prompt; self-review against step 3.
5. **Post.** `git push -u origin <branch>`, then `gh pr create --base <base> --title <title> --body-file <scratch>/pr-body-<branch>.md --draft` (drop `--draft` for `--ready`; add `--label`). Use the same literal path every time — `$TMPDIR` resolves differently sandboxed and unsandboxed. `gh` and `git push` need `dangerouslyDisableSandbox: true`. Report the URL and that it is a draft.
6. **Watch the build and fix what it breaks.** The work is not delivered until CI is green. Arm the watch in the background with `Monitor` (`persistent: true`), falling back to Bash `run_in_background` + `dangerouslyDisableSandbox` if it dies on a sandbox violation:

   ```bash
   .claude/skills/woodpecker/watch-pr-build.sh <pr> --sha $(git rev-parse HEAD)
   ```

   Don't block or poll by hand. Act on each event (the `woodpecker` skill documents every line and the log API):
   - **`STEP FAILED` / `BUILD FAILURE` / `BUILD ERROR` / `CONFIG ERROR`** — read the step log, fix, re-run `make test` / `make lint`, `/commit`, push, and **re-arm on the new HEAD sha**.
   - **`BUILD CANCELED`** — superseded by a newer push; re-arm on the new sha.
   - **`STALLED` / `QUEUED` / `NO PROGRESS` / `NO PIPELINE`** — nothing ran and GitHub shows no status; no code change fixes it. Follow the stuck-pipeline / dead-agent sections of the `woodpecker` skill.
   - **`BUILD BLOCKED`** — a human must approve the run in Woodpecker. Say so and stop.
   - **`BUILD PASSED`** — report it.

   Ask rather than guess (naming the step, the log evidence and options) when the failure is not clearly caused by this diff, when the fix would change what the PR does, or after two failed attempts on the same step. Never force-push, never merge. *Auto:* at most two fix cycles; if still red, `gh pr comment <pr> --body-file …` naming the failing step with a short log excerpt, and stop.
