# CLAUDE.md

## What this repo is

**Kestra flow content only** — flow YAML plus the shell/Python scripts flows execute. Kestra itself is installed/configured by the `salt` repo under `salt/kestra/` (read both repos' `SESSION_DEBRIEF.md` together). Every script a flow runs is vendored here — inline or under `namespace-files/` via `read()` — so the repo is self-contained at runtime. That includes `prod.backups.dev-database-backup`, whose inlined `dev_bondlink_backup.sh` defines its own `myq`/`desync`/`resync` (Galera `wsrep_desync`/`wsrep_on`, or `stop`/`start slave` on a replica) rather than sourcing the oddjob repo's `/src/oddjob/mariadb/backup_lib.sh` on the host; keep it that way, since nothing here would notice that file changing. Flow `description:` fields naming a Rundeck job/script are provenance only; `mblink/rundeck-jobs` is not a source to consult.

`SESSION_DEBRIEF.md` is a point-in-time migration snapshot: verify any "X isn't possible" claim there against current code before acting on it.

Diagnosing a production flow failure, or a `kestra.prod.bondlink.org` URL: `kestra` skill.

## Read the skill, don't skim the description

<EXTREMELY-IMPORTANT>
The one-line descriptions in the skill listing are an index, not the content. Reading a
description and proceeding is the most common failure mode here — it produces work that looks
right while quietly ignoring the helper, convention, or gate the skill exists to enforce.

Before your first edit in any task, open the `SKILL.md` of every skill the routing table maps to
that task — via the Skill tool or by reading the file — and say which ones you read. Not the
description. The file. If the routing row names four skills, read four.

"I know this area", "I read it last session", "this change is too small", and "I'll check after
the edit" are the same mistake wearing different clothes. Skills change; your recollection of one
is not the current version.
</EXTREMELY-IMPORTANT>

The routing table lives in the `using-superpowers` skill.

## Commands

```bash
make setup             # .venv + requirements-test.txt
make test              # static flow-YAML checks (pytest, no AWS) — what CI runs
make lint              # ci/lint/lint.sh all: ruff, shellcheck, ssh-commands, zsh-pitfalls (all blocking)
make test-integration  # opt-in: runs every AwsCLI task against live AWS (real creds; not in CI)
make generate-error-block  # canonical errors: boilerplate
./.venv/bin/pytest tests/unit/test_known_pitfalls.py::test_no_literal_pebble_comment_start
./.venv/bin/pytest -k "clean-basex"     # every check for one flow (test ids are flow paths)
```

- `bash ci/lint/lint.sh py|shell|ssh|zsh` scopes the gate. An empty file list is fatal by design (the linters exit 0 on no input).
- Local Kestra: copy `.env.example` to `.env` (gitignored), fill `KESTRA_SECRET_KEY` / `SECRET_*`, `docker-compose up`. `make sync` (`kestra-sync-flows.sh`) works only on the production Kestra host.
- CI: Woodpecker only (`.woodpecker.yml`, arm64: `lint`, `run-unit-tests`, failure-only mail), on push to `main` and every PR. Its `ci/woodpecker/pr/woodpecker` status is the check `main`'s branch protection requires. `woodpecker` skill.

## Layout and naming (enforced by tests)

- `flows/<env>/<group>/<flow-id>.yml`: `id:` = filename stem; `namespace:` = dot-joined path under `flows/` (`flows/prod/aws/clean-basex-backups.yml` → `id: clean-basex-backups`, `namespace: prod.aws`). Groups mirror the Rundeck `<group>` tag.
- `namespace-files/<namespace>/`: files synced into that namespace. `shared/` = used by several flows or across environments (`{{ read('x.sh', namespace='shared') }}`); a per-namespace dir like `prod.aws/` = single-flow scripts (bare `{{ read('x.sh') }}` defaults to the calling flow's namespace).
- `ops/kestra-bootstrap.yml` is **local dev only**. Production sync is a host `git pull` plus `kestra flow namespace update <ns> <dir>` and `kestra namespace files update <ns> <dir>` per namespace, driven by salt's `salt/kestra/bin/sync-flows.sh.jinja2`. OSS CLI auth is basic (`--user=USER:PASS`); `--api-token` is Enterprise-only.

## Flow anatomy

Every flow has `id`, `namespace`, `tasks`, a non-empty `errors:` and a non-empty `triggers:`. An unscheduled flow keeps a `Schedule` trigger with `disabled: true` (see `wazuh-logs.yml`, `clean-drone-resources.yml`).

Task types in use:

- `io.kestra.plugin.fs.ssh.Command` — always `bldeploy@<host>.{bondlink,staging}.vpc`, port `2007`, `authMethod: PUBLIC_KEY`, `privateKey: "{{ secret('SSH_PRIVATE_KEY') }}"`, `strictHostKeyChecking: "no"` (all six required by `test_flow_structure.py`).
- `io.kestra.plugin.notifications.sendgrid.SendGridMailSend` — SendGrid HTTPS API, not SMTP; `sendgridApiKey: "{{ secret('SENDGRID_API_KEY') }}"` and `htmlContent:` (not `htmlTextContent:` — Kestra's docs page is wrong on package and field name).
- `io.kestra.plugin.aws.cli.AwsCLI` — host discovery in its own container with instance-role creds; writes `outputFiles:`.
- `io.kestra.plugin.core.flow.ForEach` — fan out over hosts with `concurrencyLimit:`.
- `io.kestra.plugin.core.trigger.Schedule`.

Scripts reach the remote host via a **quoted heredoc** in the ssh command; `namespaceFiles:` on `ssh.Command` only stages files on the Kestra worker.

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

Host discovery:

- **Fleet** — `AwsCLI` writes `instances.json`; `ForEach` `values: "{{ fromJson(read(outputs.<task>.outputFiles['instances.json'])) }}"`, per-host `{{ fromJson(taskrun.value).PrivateDnsName }}` (see `bondlink-logs.yml`).
- **Exactly one host** — `namespace-files/shared/aws_query.sh privateDsnByTagName <Name tag>` writes `host.txt` (fails on 0 or >1 matches); `host: "{{ read(outputs.<task>.outputFiles['host.txt']) }}"`, no ForEach (see `staging/haproxy/certificate-renewal.yml`).

## Pitfalls the test suite enforces

Each of these was a real bug in a committed flow; each test in `tests/unit/test_known_pitfalls.py` documents its incident in a comment.

- **`/usr/local/bin/aws`, never bare `aws`** in `ssh.Command` scripts and `namespace-files/**/*.sh` — the non-interactive SSH PATH lacks `/usr/local/bin` (exit 127). `AwsCLI` tasks are exempt.
- **No literal `{#` in `tasks`/`errors`/`triggers`** — Pebble reads it as a comment start, so bash `${#arr[@]}` fails at execution with `ParserException: Unclosed comment`. Move the script to a namespace file (`read()` output is never re-parsed). Top-level `description:` is exempt.
- **`/opt/saltstack/salt/bin/python3`, never bare `python3`** or `#!/usr/bin/env python3` — system python3 (3.12) lacks `boto3`/`more_itertools`; salt onedir (3.14) has them. A bare invocation ignores the script's shebang.
- **`fromJson(taskrun.value).Field`, never `taskrun.value.Field`** — `taskrun.value` is a JSON string.
- **No notification task inside a `ForEach`** — it fires per iteration; put it after the loop.
- **Lowercase AWS tag filter values** (`Values=prod`) — case-sensitive; a mismatch silently matches nothing.
- **`ensure_salt_perms.sh` before any `salt-run`** (`tests/unit/test_salt_perms.py`) — fixes the getfacl/setfacl ACL on `/var/cache/salt/minion/roots/mtime_map`, without which it fails on permissions. Not needed for `salt-call` or bare `salt <target>`.
- **A prod flow's `errors:` must not mention staging, and vice versa** (`tests/unit/test_environment_isolation.py`) — that block is pure boilerplate, so a cross-environment reference is always a copy/paste mistake.

Lint-enforced: the inline `commands:` block runs in `bldeploy`'s login shell, **zsh** (salt's `pillar/base/users/init.sls`); vendored scripts are written to `/tmp`, `chmod +x`'d and executed, so their bash shebang wins. Use `$(hostname)`, not `$HOSTNAME` (empty in zsh); never assign `status` (read-only `$?` alias in zsh; aborts under `set -e` before anything runs). Both shipped to production. `ci/lint/check_zsh_pitfalls.py` gates read-only parameters, tied arrays like `path`, bash-only variables and zero-indexed subscripts; `ci/lint/check_ssh_commands.py` checks the blocks as `/bin/sh`. Shellcheck's bash mode (passes both bugs) and `zsh -n` (syntax only) are no substitute.

Not checked: arithmetic derived from `nproc` needs a floor of 1 — `prodsalt-arm` is 1 vCPU, and `wait -n` with no background jobs exits 127.

## Secrets

`{{ secret('NAME') }}`, provisioned as `SECRET_`-prefixed env vars: `SSH_PRIVATE_KEY` (base64 `bldeploy` key) and `SENDGRID_API_KEY` for every flow; `GITHUB_SSH_PRIVATE_KEY` only for `ops/kestra-bootstrap.yml`. Production populates them via salt's `kestra` state (`/etc/kestra/.env`).

Working from a workstation:

- **Never pass a secret as a CLI argument** — argv is visible in `ps`, shell history and CI logs. Pipe it via stdin: `printf 'Authorization: Bearer %s' "$TOK" | curl -H @- …`. Never `echo` one.
- **Per-user secrets live in the macOS Keychain.** Read into a variable: `TOK=$(security find-generic-password -s <service> -w)`. Store with `printf 'token: '; IFS= read -rs T; echo; security add-generic-password -s <service> -a <you@bondlink.com> -w "$T"; unset T` — **not** the bare `-w` prompt, which silently truncates long tokens (a 192-character token stored as 128); check the stored length before trusting it.
- **AWS: mint a scoped token (`scoped-aws-credentials`)** rather than using your read-write IAM user. The Bash sandbox does not confine `aws`.

## Comments, commit messages and PR descriptions describe the change, not the session

- A comment states a constraint or footgun the code cannot carry, in one or two lines — never how the code got here ("previously", "renamed from", a bug hit while writing it) and never a figure read off a run.
- Commits and PR bodies: present tense, end state, every line about this diff; a subject plus at most a few bullets, a PR one or two sentences plus bullets. No verification narration, no rejected alternatives, no AI attribution of any kind. In PR bodies each paragraph and bullet is one line. `/commit` and `/pr` carry the full rules; PRs open as drafts.
