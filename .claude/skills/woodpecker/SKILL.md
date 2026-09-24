---
name: woodpecker
description: Access BondLink's Woodpecker CI (woodpecker.bondlink.org) to inspect this repo's pipelines, read failed-step logs, and restart — via the HTTP API with a Keychain-stored token. Use when a kestra-automation CI build fails, when watching a PR's build to completion (`watch-pr-build.sh`), when a pipeline never starts or hangs, or before editing `.woodpecker.yml`.
---

# Woodpecker CI (kestra-automation)

`https://woodpecker.bondlink.org`, arm64 agents. The API is id-based: this repo is **repo id `7`** (`wapi repos/lookup/mblink/kestra-automation`). Woodpecker is the only CI here — there is no GitHub Actions workflow — and its `ci/woodpecker/pr/woodpecker` status is the check branch protection requires.

## Credentials

Token: macOS Keychain, service exactly **`woodpecker.bondlink.org`** (create under *User Settings* in the UI; store with `printf 'token: '; IFS= read -rs T; echo; security add-generic-password -s woodpecker.bondlink.org -a <you@bondlink.com> -w "$T"; unset T` — not the bare `-w` prompt, which silently truncates long tokens). Keychain reads and `curl` to the server need the sandbox disabled.

```bash
WP_TOKEN=$(security find-generic-password -s woodpecker.bondlink.org -w 2>/dev/null)
[ -z "$WP_TOKEN" ] && { echo "no Woodpecker token in Keychain (service=woodpecker.bondlink.org)"; exit 1; }
wapi() { printf 'Authorization: Bearer %s' "$WP_TOKEN" | curl -s -H @- "https://woodpecker.bondlink.org/api/$1"; }
```

Never `-H "Authorization: Bearer $TOKEN"` (argv, visible to `ps`); never echo the token; don't guess Keychain names.

## Common operations (`R=repos/7`)

```bash
# pipelines (on pull_request, .branch is the TARGET — match .commit or .title for a PR)
wapi "$R/pipelines?perPage=30" | jq -r '.[] | "pipeline=\(.number) \(.status) \(.event) branch=\(.branch) \(.commit[0:9])"'
# which step failed (steps are workflows[].children[])
wapi "$R/pipelines/<n>" | jq -r '.workflows[] | "WORKFLOW \(.name) [\(.state)]", (.children[] | "  id=\(.id) pid=\(.pid) \(.name) [\(.state)]")'
# step log: by step id (not pid); data is base64 per entry
wapi "$R/logs/<n>/<stepId>" | jq -r '.[].data' | base64 -d | grep -niE "error|failed|FAILED|SC[0-9]{4}" | tail -40
```

- Grep, don't eyeball: `lint.sh` prints a per-linter section and a final `summary: N check(s) reported problems`; pytest's failures are in its short summary at the end.
- **Failed with no step run** = config-compile error in the pipeline's top-level `errors[]` (`type: "compiler"`). Usual cause: a dollar-brace sequence anywhere in `.woodpecker.yml` — envsubst runs over the raw text, comments included, before YAML parsing. Use bare `$VAR` (expanded by the step shell at runtime).
- Restart: `POST $R/pipelines/<n>` with the same `-H @-` pattern.

## Pipeline (`.woodpecker.yml`)

One workflow, `labels: platform: linux/arm64`, image `drone-kestra:latest-arm64` from ECR (built in the `mblink/oddjob` repo). Triggers: push/manual to `main`, and every `pull_request` (no branch filter, so stacked PRs get a status too). Repo settings (`wapi repos/7`): not trusted, 60-minute timeout, `cancel_previous_pipeline_events: [push, pull_request]` — a new push kills the in-flight build on the same branch, so a `killed` pipeline is usually that.

Steps: `clone` → `lint` → `run-unit-tests` → `notify`.

- **`lint`** — `pip install -r requirements-test.txt`, then `bash ci/lint/lint.sh all` (ruff, shellcheck on every tracked `*.sh`, the ssh-commands and zsh-pitfalls gates). Same as `make lint`.
- **`run-unit-tests`** — `pytest -v tests/unit`. `make test` is the local equivalent (it also skips `integration`).
- **`notify`** — `when: status: [failure]` only; `alpine` + `msmtp` mails the commit author through `prodsalt-arm.bondlink.vpc:25`. Skipped on a green build.

## Watching a PR build

```bash
.claude/skills/woodpecker/watch-pr-build.sh <pr> [--sha <commit>] [--interval 30] [--wait 600] [--idle 2400]
```

- Arm via `Monitor` with `persistent: true` (default 300s timeout is shorter than a build). If it dies on a sandbox network violation, run via Bash with `run_in_background: true` + `dangerouslyDisableSandbox: true`. It uses Woodpecker and the Keychain only, not `gh`.
- Repo id is derived from `origin` (`/api/repos/lookup/<owner>/<name>`).
- Emits `WATCHING`, `CONFIG ERROR` (from `errors[]`), `STEP FAILED <name> … log: repos/<id>/logs/<n>/<stepId>` per failing step, then one terminal line: `BUILD PASSED` / `BUILD SKIPPED` / `BUILD FAILURE|ERROR|DECLINED` / `BUILD CANCELED` / `BUILD BLOCKED` / `STALLED` / `QUEUED` / `NO PROGRESS` / `NO PIPELINE`. Exit 0: `BUILD PASSED`, `BUILD SKIPPED` or `BUILD CANCELED`; 1: `BUILD FAILURE|ERROR|DECLINED`; 2: `BUILD BLOCKED` / `STALLED` / `QUEUED` / `NO PROGRESS` / `NO PIPELINE`, or a usage/setup error (stderr only). **Exit 0 is not "passed" — read the terminal line:** `BUILD PASSED` is the only pass, `BUILD CANCELED` means re-arm with `--sha` on the newer commit, and `BUILD SKIPPED` means nothing ran for this sha.
- Pass `--sha $(git rev-parse HEAD)` after pushing a fix, or the previous failure is reported again. Without `--sha`, a `killed` pipeline gets one extra poll (a newer push may have replaced it) before being called canceled; with `--sha` it exits straight away.
- The nothing-ran outcomes post no GitHub status at all, so a `gh pr checks`-style watch stays silent through every one — silence is not success. `STALLED` / `QUEUED` / `NO PROGRESS` / `NO PIPELINE` mean no code change will fix it: diagnose with the next three sections.
- Every PR builds whatever its base, so `NO PIPELINE` is never the trigger filter — treat it as a stuck pipeline.

## A stuck pipeline: check the server log, not the stored config

A pipeline that never runs sits with `started: 0`, no `errors[]`, no steps and nothing in the queue — indistinguishable from a queued build, and GitHub gets no status either way. Causes: the DAG compiler panic (next section) or a failed forge fetch. The stored config does not reliably tell them apart:

| observed | cause |
| --- | --- |
| `status: created`, config `[]` | panic on the **webhook** path (crashes before the config is stored) |
| `status: pending`, config present | panic on the **restart** path |

The server log is authoritative (server runs on `prodwoodpecker`):

```bash
docker logs --since 10m woodpecker-woodpecker-1 2>&1 | grep -iE 'nil pointer|dag.go|panic'
wapi repos/7/pipelines/<N>/config   # context, not a verdict
```

`POST repos/7/pipelines/<N>` replays the **stored** config:

- **config present** — restarting works; each attempt is an independent coin flip.
- **config `[]`** — restarting fails with `pipeline definition not found`. Force a fresh creation event: push another commit, or close and reopen the PR. `manual` is in this repo's `when` but only for `main`.

## The DAG compiler panics on `optional` deps

Woodpecker v3.16 (unfixed upstream) can crash with a nil pointer dereference while compiling a config (`pipeline/frontend/yaml/compiler/dag.go:85`). `convertDAGToStages` iterates steps in Go map order (random), resolving each step's `depends_on` and dropping `optional` edges to steps pruned by `when`; if the walk reaches an unresolved step whose `depends_on` still names a pruned step, it panics. The pipeline is left with no workflows, stuck forever, and the same config can succeed on one attempt and die on the next.

**This repo's `.woodpecker.yml` uses no `depends_on` and no `optional`** — steps run in file order, and `notify` gates on `when: status` — so its current config cannot hit the panic. If you add `depends_on`:

- A required `depends_on` naming a step pruned by `when` is a compile error (`ErrStepMissingDependency`); mark it `{name: <step>, optional: true}`. `optional` matters only when the step is absent.
- **Invariant:** any step carrying an `optional` dependency on an event-gated step must have **no dependents**. Check each event the pipeline is created for (`push`, `pull_request`, `manual`) before merging.

## A hung pipeline may be a dead or duplicate agent, not a stuck build

Steps sitting in `running` forever, log frozen mid-step, usually mean nothing is executing them:

```bash
wapi queue/info | jq '.stats'          # worker_count 0 => no agent is connected at all
wapi agents      | jq '.[] | {id, name, platform, last_contact}'
wapi repos/7/pipelines/<N> | jq '.workflows[].children[] | {name, state, started}'
```

- **`worker_count: 0`** — no agent connected. A healthy agent contacts the server every few seconds; a `last_contact` minutes old means it is gone even if its EC2 instance is `running` and passing status checks. This repo needs a `linux/arm64` agent.
- **Several agent rows with the same name** — the agent re-registered instead of reclaiming its id; a pipeline dispatched to a vanished `agent_id` sits `running` forever. Cancel and re-trigger.
- **A step frozen with no output** is not evidence about that step — the log stops when the agent stops streaming. Diagnose from the agent side first.
- If the agent host is unresponsive, a console reboot often won't complete; `stop --force` then `start` is the reliable escalation.
- `QUEUED` (pending, no change): check `worker_count` before assuming a slow build — other repos' pipelines share the agents.
