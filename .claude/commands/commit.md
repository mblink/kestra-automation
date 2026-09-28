---
description: Review the session's changes, compose a terse commit message, and commit — no approval prompt
argument-hint: [--auto]
---

Commit the current working tree: review, verify, then commit. `--auto` in `$ARGUMENTS` means an autonomous caller — no prompts; differences noted per step. Verification is never skipped.

1. **Branch.** `git branch --show-current`. On `main` (protected; changes land by PR): ask for a branch name or derive a short kebab-case slug with a conventional prefix (e.g. `fix/zsh-status-accumulator`, `chore/…`) and `git checkout -b`. *Auto:* abort with an error.
2. **Review.** `git status --short`, full `git diff` (and `--cached`). Stage only this change's files — never `git add -A` blind; never stage `.env`, `.venv/` or `tests/integration_cache/`. Ask about unrelated/unexpected changes. *Auto:* exclude them and note it in the report.
3. **Verify, scoped to the diff** (skip a check already run with no edits since; never commit with failing or stale verification):
   - `flows/**`, `namespace-files/**`, `tests/**`, `ci/**`, any `*.py`/`*.sh` → `make test` and `make lint` (`make setup` first; `lint.sh` finds `ruff` on `PATH`, so `PATH="$PWD/.venv/bin:$PATH" make lint`; `mktemp` in it needs the sandbox disabled). Scope with `./.venv/bin/pytest -k <flow-id>` or `bash ci/lint/lint.sh py|shell|ssh|zsh` while iterating, but run both full targets before committing.
   - A new `*.sh` is linted only once tracked (`lint.sh` resolves files with `git ls-files`): stage it, then run `bash ci/lint/lint.sh shell`.
   - `.woodpecker.yml` → no local runner; re-read it for a dollar-brace sequence (fatal to Woodpecker's envsubst, comments included) and rely on the PR build (`woodpecker` skill).
   - Docs only → nothing.
4. **Compose** per `CLAUDE.md` ("Comments, commit messages and PR descriptions"):
   - Subject line; a body only when the subject can't carry it — bullets (one unwrapped line each) or a table, three or four at most.
   - Every line describes this diff: present tense, end state; no history, no play-by-play, no rejected alternatives, no verification narration. A pre-existing defect gets a sentence only if the reader needs it — always name one that affects a scheduled production flow.
   - No AI attribution of any kind (`Co-Authored-By`, `Claude-Session` trailer, "Generated with …"), even if a harness rule says otherwise.
5. **Commit** with `git commit -F - <<'EOF' … EOF` (not repeated `-m`), so body lines stay single, unwrapped lines. Confirm with `git log -1 --stat` and quote the message. Don't push unless asked (or continuing into `/pr`).
