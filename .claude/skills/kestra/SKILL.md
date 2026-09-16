---
name: kestra
description: Query the production Kestra API to find out why a flow failed — read execution history, download task logs, and read back the flow revision that is actually deployed. Use whenever a flow failure needs diagnosing, whenever someone pastes a kestra.prod.bondlink.org URL, and before concluding a flow's behaviour from the YAML in this repo, because what runs in production is a numbered revision that can differ from any branch.
---

# Reading production Kestra

`bin/kestra-api.sh <path> [key==value | curl-args]...` is the client. It prepends
`https://kestra.prod.bondlink.org/api/v1/main`, so paths start at `/executions`, `/flows`, `/logs`.

```
bin/kestra-api.sh /executions/search namespace==prod.aws flowId==clean-basex-backups size==20
bin/kestra-api.sh /logs/<executionId>/download
bin/kestra-api.sh /flows/prod.aws/clean-basex-backups
```

`key==value` becomes a URL-encoded query parameter; anything else is passed to curl.

## The API is not read-only. The client is.

This OSS deployment has **no RBAC**. Basic auth is a single admin account — the same
`pillar['kestra']['admin_username'/'admin_password']` that `salt/kestra/bin/sync-flows.sh.jinja2`
uses — and that credential can create, update and delete flows, trigger executions and edit
namespace files. Scoped API tokens and service accounts are Enterprise-only; `--api-token` does not
work here.

So read-only is enforced client-side: the script always passes `--get` and rejects `-X`, `--request`,
`-d`, `--data*`, `-F`, `--form` and `-T`, the flags curl needs to express a write. It pipes the
credential to curl through `--config -`, so the secret never lands on disk and never appears in `ps`.
The guard assumes Kestra mutates nothing on a GET, which matches its REST conventions but is not
enforced by the server.

**Never** use the credential to push flows. Production sync is a host-level `git pull` plus
`kestra flow namespace update`, driven by salt. `.claude/settings.json` denies those commands.

## Diagnosing a failed flow

1. **Find the execution.** Sort descending and read the `state.current` and `flowRevision` of each:

   ```
   bin/kestra-api.sh /executions/search namespace==prod.aws flowId==<flow> size==20
   ```

   Pipe through `python3 -c` to table it — the raw JSON is enormous. `total` is the lifetime count.

2. **Read the logs.** `/logs/<executionId>/download` returns plain text, newest task last. The first
   `ERROR` line is the real cause; the `java.lang.Exception: SSH command fails with exit status N`
   below it is only Kestra reporting that the remote shell exited non-zero.

3. **Compare revisions before reading any YAML.** This is the step that is easy to skip and expensive
   to skip.

## What runs in production is a revision, not a branch

Executions carry a `flowRevision`. Kestra increments it on every sync, and **it does not correspond
to any git ref** — nothing in the API maps revision 8 back to a commit. Your checkout is not
evidence of what is deployed.

Two traps follow, and the second one caught this skill's own author:

- Diagnose against the definition the API returns, not against whatever branch is checked out.
- **`git fetch` before you compare anything to `main`.** A stale local `main` made revision 8 look
  like an out-of-band deploy from an unmerged branch, and that framing survived several confident
  paragraphs before it was checked. It was wrong: PR #26 merged at 2026-09-15T20:44Z, production
  synced it, and the first scheduled run failed at 2026-09-16T10:00Z. An ordinary merge that
  shipped a bug — the common case, and the one to expect.

Always read the deployed definition back:

```
bin/kestra-api.sh /flows/prod.aws/<flow> | python3 -c "
import sys,json; d=json.load(sys.stdin)
print('revision:', d['revision']); print(d['tasks'][0]['commands'][0])"
```

A revision that changed on the day the failures started is the prime suspect. Walk the history —
`SUCCESS` at revision 7 and `FAILED` at revision 8, first run after the bump, is a deployment
regression, not a drifting-infrastructure problem.

`{{ read('x.sh') }}` in the returned definition is **unrendered**: the flow body holds the Pebble
expression, and the namespace file is stored separately. Fetch the deployed script itself with
`bin/kestra-api.sh /namespaces/<ns>/files path==/x.sh` — but note that namespace files are **not**
versioned alongside the flow, so that returns the current file, not necessarily the one that ran.

## The inline block runs zsh, and that is a bug source

`ssh.Command` sends the `commands:` block over SSH exec, so the remote user's login shell runs it.
`bldeploy`'s shell is `/bin/zsh` (`pillar/base/users/init.sls` in the salt repo). Only the inline
block is zsh — the vendored scripts are written to `/tmp`, `chmod +x`'d and executed, so their
`#!/usr/bin/env bash` shebang wins, and real bash applies there.

Two production incidents came from this, both invisible to shellcheck:

- `$HOSTNAME` is empty in zsh (it uses `$HOST`), which collapsed three staging hosts onto the S3 key
  `suricata-logs//`. Use `$(hostname)`.
- `status=0` — `status` is a read-only alias for `$?` in zsh, so the assignment aborted the task
  under `set -e` before anything ran.

`ci/lint/check_zsh_pitfalls.py` now gates the second class (read-only parameters, tied arrays like
`path`, bash-only variables, zero-indexed subscripts). `ci/lint/check_ssh_commands.py` checks the
same blocks as `/bin/sh`. Neither can be replaced by shellcheck's bash mode, which would pass both
bugs, or by `zsh -n`, which only checks syntax.

## Endpoints worth knowing

| path | returns |
|---|---|
| `/executions/search` | execution list; `namespace`, `flowId`, `size`, `sort=state.startDate:desc` |
| `/logs/<executionId>/download` | plain-text logs for one execution |
| `/logs/<executionId>` | the same as JSON, with `minLevel=INFO` etc. |
| `/flows/<namespace>/<id>` | the deployed definition and its `revision` |
| `/flows/<namespace>/<id>/revisions` | every stored revision, oldest first |
| `/namespaces/<namespace>/files/directory` | namespace-file listing |
| `/namespaces/<namespace>/files` + `path==/x.sh` | one namespace file's contents |

The tenant segment is `main`, matching the `/ui/main/...` in browser URLs. A 401 rather than a 404
means the path is right and only auth failed.
