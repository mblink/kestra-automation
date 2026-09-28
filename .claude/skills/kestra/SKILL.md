---
name: kestra
description: Query the production Kestra API to find out why a flow failed — read execution history, download task logs, and read back the flow revision that is actually deployed. Use whenever a flow failure needs diagnosing, whenever someone pastes a kestra.prod.bondlink.org URL, and before concluding a flow's behaviour from the YAML in this repo, because what runs in production is a numbered revision that can differ from any branch.
---

# Reading production Kestra

`bin/kestra-api.sh <path> [key==value | curl-args]...` prepends `https://kestra.prod.bondlink.org/api/v1/main`; `key==value` becomes a URL-encoded query parameter, anything else goes to curl.

```bash
bin/kestra-api.sh /executions/search namespace==prod.aws flowId==clean-basex-backups size==20
bin/kestra-api.sh /logs/<executionId>/download
bin/kestra-api.sh /flows/prod.aws/clean-basex-backups
```

## Read-only is enforced by the client, not the server

OSS Kestra has no RBAC: basic auth is the single admin account (`pillar['kestra']['admin_username'/'admin_password']`, as used by salt's `sync-flows.sh.jinja2`), which can create/update/delete flows, trigger executions and edit namespace files. Scoped API tokens and service accounts are Enterprise-only; `--api-token` does not work here.

The script always passes `--get`, rejects `-X`, `--request`, `-d`, `--data*`, `-F`, `--form`, `-T`, and feeds the credential via `--config -` (never on disk or in `ps`). The guard assumes Kestra mutates nothing on a GET (its REST convention, not server-enforced). **Never use the credential to push flows** — sync is salt's `git pull` + `kestra flow namespace update`, and `.claude/settings.json` denies those commands.

## Diagnosing a failed flow

1. **Find the execution** — `/executions/search … size==20`; read each `state.current` and `flowRevision` (table it with `python3 -c`; raw JSON is huge; `total` is the lifetime count).
2. **Read the logs** — `/logs/<executionId>/download`, newest task last. The first `ERROR` line is the cause; the following `SSH command fails with exit status N` just reports the remote exit.
3. **Compare revisions before reading any YAML.**

## Production runs a revision, not a branch

`flowRevision` increments on every sync and maps to no git ref, so your checkout is not evidence of what ran. Diagnose against the definition the API returns, and **`git fetch` before comparing anything to `main`** — a stale local `main` makes an ordinary merged regression look like an out-of-band deploy (it happened with PR #26: merged, synced, failed on its first scheduled run — the common case, and the one to expect).

```bash
bin/kestra-api.sh /flows/prod.aws/<flow> | python3 -c "
import sys,json; d=json.load(sys.stdin)
print('revision:', d['revision']); print(d['tasks'][0]['commands'][0])"
```

A revision bump on the day failures started (`SUCCESS` at N, `FAILED` from N+1) is a deployment regression. `{{ read('x.sh') }}` in the returned definition is unrendered; fetch the script with `/namespaces/<ns>/files path==/x.sh` — namespace files aren't versioned with the flow, so that's the current file, not necessarily the one that ran.

Inline `commands:` blocks run under `bldeploy`'s login shell, zsh (`ssh.Command` uses SSH exec) — a bug source invisible to shellcheck (`$HOSTNAME` empty, `status` read-only). See `CLAUDE.md` → "Pitfalls the test suite enforces".

## Endpoints

| path | returns |
|---|---|
| `/executions/search` | executions; `namespace`, `flowId`, `size`, `sort=state.startDate:desc` |
| `/logs/<executionId>/download` | plain-text logs |
| `/logs/<executionId>` | JSON logs, `minLevel=INFO` etc. |
| `/flows/<namespace>/<id>` | deployed definition + `revision` |
| `/flows/<namespace>/<id>/revisions` | all stored revisions, oldest first |
| `/namespaces/<namespace>/files/directory` | namespace-file listing |
| `/namespaces/<namespace>/files` + `path==/x.sh` | one file's contents |

Tenant segment is `main` (as in `/ui/main/...` URLs). A 401 (not 404) means the path is right and auth failed.
