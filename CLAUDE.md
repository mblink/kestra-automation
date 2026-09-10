# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

**Kestra flow content only** — flow YAML plus the shell/Python scripts those flows execute. It does
not install or configure Kestra itself; that lives in the separate `salt` repo under `salt/kestra/`
(the two repos' `SESSION_DEBRIEF.md` files are meant to be read together). Every script a flow runs
is vendored here — inlined in the flow, or under `namespace-files/` and pulled in with `read()` — so
this repo is self-contained at runtime. Flow `description:` fields name a Rundeck job and script
path; that is provenance only, and `mblink/rundeck-jobs` is not a source to consult.

`SESSION_DEBRIEF.md` is a point-in-time migration snapshot, not living documentation: verify any
"X isn't possible" claim there against current code/tooling before acting on it.

## Commands

```
make setup             # create .venv and install requirements-test.txt
make test              # static flow-YAML checks (pytest, no AWS calls) — what CI runs
make lint              # ruff over *.py + shellcheck over *.sh (blocking; see ci/lint/lint.sh)
make test-integration  # opt-in: executes every AwsCLI task against live AWS (real creds, not in CI)
```

Single test / single flow:

```
./.venv/bin/pytest tests/unit/test_known_pitfalls.py::test_no_literal_pebble_comment_start
./.venv/bin/pytest -k "clean-ecr"       # every check for one flow (test ids are flow paths)
```

`bash ci/lint/lint.sh py|shell` scopes the lint gate. `ci/lint/lint.sh` treats an empty file list as
fatal — both linters exit 0 on no input, so a resolver failure would silently make the gate a no-op.

Local Kestra: `docker-compose up` after copying `.env.example` to `.env` (gitignored) and filling in
`KESTRA_SECRET_KEY` / `SECRET_*` values. `make sync` (`kestra-sync-flows.sh`) only works on the
production Kestra host, not locally.

CI: `.github/workflows/pytest.yml` (`make setup` + `make test`) on PRs, plus `.woodpecker.yml`
(arm64-only, `lint` + `run-unit-tests` + a failure-only mail step).

## Layout and naming rules (enforced by tests)

- `flows/<env>/<group>/<flow-id>.yml` — `id:` must equal the filename stem and `namespace:` must
  equal the dot-joined directory path under `flows/` (`flows/prod/aws/clean-ecr.yml` →
  `id: clean-ecr`, `namespace: prod.aws`). Group directories mirror the source Rundeck `<group>` tag.
- `namespace-files/<namespace>/` — files synced into that Kestra namespace. `shared/` holds scripts
  used by more than one flow or shared across environments (read with
  `{{ read('x.sh', namespace='shared') }}`); a per-namespace dir like `prod.aws/` holds
  single-flow scripts (bare `{{ read('x.sh') }}` — `read()` defaults to the calling flow's namespace).
- `ops/kestra-bootstrap.yml` — **local dev only**. Production sync is a host-level `git pull` plus
  `kestra flow namespace update <ns> <dir>` and `kestra namespace files update <ns> <dir>` per
  namespace, driven by `salt/kestra/bin/sync-flows.sh.jinja2` in the salt repo. OSS CLI auth is
  HTTP basic (`--user=USER:PASS`); `--api-token` is Enterprise-only.

## Flow anatomy

Every flow has `id`, `namespace`, `tasks`, a non-empty `errors:` block, and a non-empty `triggers:`
block. A flow with no schedule still needs a `Schedule` trigger carrying `disabled: true` rather than
an omitted block (see `wazuh-logs.yml`, `clean-drone-resources.yml`).

Only five task types are in use:

- `io.kestra.plugin.fs.ssh.Command` — the workhorse. Always `bldeploy@<host>.{bondlink,staging}.vpc`,
  port `2007`, `authMethod: PUBLIC_KEY`, `privateKey: "{{ secret('SSH_PRIVATE_KEY') }}"`,
  `strictHostKeyChecking: "no"` (all six fields required by `test_flow_structure.py`).
- `io.kestra.plugin.notifications.sendgrid.SendGridMailSend` — SendGrid's HTTPS API, not SMTP;
  `sendgridApiKey: "{{ secret('SENDGRID_API_KEY') }}"` and `htmlContent:` (not `htmlTextContent:`;
  Kestra's own docs page for this task is wrong on both the package name and the field name).
  `make generate-error-block` prints the canonical `errors:` boilerplate.
- `io.kestra.plugin.aws.cli.AwsCLI` — host discovery. Runs in its own container with real AWS creds
  from the instance role, writes to `outputFiles:`.
- `io.kestra.plugin.core.flow.ForEach` — fan out over discovered hosts, with `concurrencyLimit:`.
- `io.kestra.plugin.core.trigger.Schedule`.

Getting a script onto the remote host: render it into a **quoted heredoc** inside the ssh command.
`namespaceFiles:` on an `ssh.Command` task does nothing useful — it stages files into the Kestra
worker's local working dir, not the remote host.

```yaml
commands:
  - |
    set -e
    cat > /tmp/x.sh <<'X_SCRIPT'
    {{ read('x.sh', namespace='shared') }}
    X_SCRIPT
    chmod +x /tmp/x.sh
    /tmp/x.sh
    rm -f /tmp/x.sh
```

Two host-discovery shapes:

- **Fleet** — an `AwsCLI` task writes `instances.json`, then
  `values: "{{ fromJson(read(outputs.<task>.outputFiles['instances.json'])) }}"` on a `ForEach`,
  with per-host fields as `{{ fromJson(taskrun.value).PrivateDnsName }}` (see `bondlink-logs.yml`).
- **Exactly one host** — `namespace-files/shared/aws_query.sh privateDsnByTagName <Name tag>` writes
  `host.txt` (it fails loudly on 0 or >1 matches), consumed directly as
  `host: "{{ read(outputs.<task>.outputFiles['host.txt']) }}"` — no ForEach
  (see `staging/haproxy/certificate-renewal.yml`).

## Pitfalls the test suite enforces

Each of these was a real bug in a committed flow; `tests/unit/test_known_pitfalls.py` documents the
incident in the test's own comment.

- **`/usr/local/bin/aws`, never bare `aws`**, in `ssh.Command` scripts and in `namespace-files/**/*.sh`.
  Kestra's non-interactive SSH session has `/usr/bin` on PATH but not `/usr/local/bin` → exit 127.
  `AwsCLI` tasks are exempt (bare `aws` is correct inside their container).
- **No literal `{#` in `tasks`/`errors`/`triggers`.** Kestra renders these through Pebble, which reads
  `{#` as a comment start; bash's `${#arr[@]}` length syntax therefore fails at *execution* time with
  `ParserException: Unclosed comment`. Fix by moving the script to a namespace file — `read()`'s
  return value is never re-parsed as a template. (Top-level `description:` is not rendered and is
  exempt.)
- **`/opt/saltstack/salt/bin/python3`, never bare `python3`** (and no generic `#!/usr/bin/env python3`
  shebang). System python3 is 3.12 without `boto3`/`more_itertools`; the salt onedir python is 3.14
  and has them. A bare invocation resolves via PATH and silently ignores the script's shebang.
- **`fromJson(taskrun.value).Field`, never `taskrun.value.Field`** — in a `ForEach` over objects,
  `taskrun.value` is a JSON string.
- **No notification task nested inside a `ForEach`** — it fires once per iteration instead of once
  per execution. Put it at top level after the loop.
- **Lowercase AWS tag filter values** (`Values=prod`, not `Values=Prod`); filters are case-sensitive
  and a mismatch silently matches zero instances.
- **`ensure_salt_perms.sh` before any `salt-run`** (`tests/unit/test_salt_perms.py`) — without the
  getfacl/setfacl ACL fix on `/var/cache/salt/minion/roots/mtime_map` the command fails on permissions.
  Scoped to `salt-run` only; `salt-call` and bare `salt <target>` don't need it.
- **A prod flow's `errors:` block must not mention staging, and vice versa**
  (`tests/unit/test_environment_isolation.py`) — that block is pure boilerplate, so a cross-environment
  reference there is always a copy/paste mistake.

Non-obvious and not statically checked: integer arithmetic derived from `nproc` needs a floor of 1 —
`prodsalt-arm` is a 1-vCPU instance, and `wait -n` with zero background jobs exits 127.

## Secrets

Referenced as `{{ secret('NAME') }}`, provisioned as env vars prefixed `SECRET_`:
`SSH_PRIVATE_KEY` (base64-encoded `bldeploy` key) and `SENDGRID_API_KEY` for every flow;
`GITHUB_SSH_PRIVATE_KEY` only for `ops/kestra-bootstrap.yml`. Production populates these via the salt
repo's `kestra` state (`/etc/kestra/.env`), not from anything here.
