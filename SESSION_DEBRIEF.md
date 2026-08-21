# Session debrief: Rundeck → Kestra migration

> **This is a point-in-time snapshot, not living documentation.** It describes the
> state of the migration as of whenever it was last updated — treat any claim here
> (especially "X isn't possible yet" / "X doesn't exist") as something to verify
> against the current code/tooling before acting on it, not as settled fact. Update
> this file when you find it stale, the way you'd fix a bug.

This repo (`github.com/mblink/kestra-automation`) holds **Kestra flow content only** —
flow YAML and nothing else. It does not install or configure Kestra itself; that's a
separate concern, owned by the `salt` repo's `salt/kestra/` state. See that repo's own
`salt/kestra/SESSION_DEBRIEF.md` for the installation/infrastructure side of this same
migration — the two documents are meant to be read together.

## What's here

Source jobs are Rundeck's, exported from a separate `rundeck-jobs` repo (`Prod/*.xml`,
`Staging/rundeck-staging_cron/jobs/*.xml`). Converted so far:

- `flows/prod/{aws,backups,database,haproxy,security}/` — started as 5 pilot flows
  (one per structural pattern found in the ~31 Prod jobs), since reconciled against
  the rest of `rundeck-jobs/Prod/*.xml` as jobs were found/deleted there: 19 Prod
  flows total now. Two source jobs were deliberately NOT migrated: `044dbb1e` (Sync
  Vulnerabilities — disabled at the source, needs a `scala-cli` runtime this repo
  doesn't provide) and `11e0edb8` ("SaltRun: Backups BondLinkReporting" — a stale
  duplicate of `0bb392d4`'s flow of the same name; no `<schedule>`/`<group>` block,
  targets a CNAME-aliased hostname of the same host). Namespace directories
  (`prod/aws`, `prod/database`, ...) map directly to each source job's Rundeck
  `<group>` tag — `prod/logs`, `prod/ops`, `prod/suricata`, `prod/wazuh` stay empty
  since no migrated job's group ever matched those names exactly.
- `flows/staging/{backups,haproxy,suricata}/` — all 11 Staging jobs, fully converted
  (not just a pilot subset).
- `ops/kestra-bootstrap.yml` — **local-dev convenience only**. Uses Kestra's own
  internal `io.kestra.plugin.git.SyncFlows` to pull this repo into a local Kestra
  instance. This is explicitly *not* how production sync works (see below).

Every flow uses `io.kestra.plugin.fs.ssh.Command` to exec against the target
Rundeck-equivalent host directly (`bldeploy@<host>.{bondlink,staging}.vpc:2007`,
same SSH key Rundeck itself already uses), and
`io.kestra.plugin.notifications.sendgrid.SendGridMailSend` for failure/success email
(SendGrid's HTTPS API directly, not SMTP — no host/port/TLS/mail-domain config needed,
just an API key).

Shared scripts that used to live in `rundeck-jobs`' `aws/`, `databases/`, `haproxy/`,
`logs/` folders are mostly still **inlined directly into each flow's `commands:`**
via quoted heredocs (`<<'DELIM'`), rather than pulled from Kestra's Namespace Files
feature — that mechanism was originally tried and dropped for simplicity, partly
because the Kestra CLI had no way to sync Namespace Files (only flows). That CLI gap
is gone (`kestra namespace files update <namespace> <dir>` now exists, mirroring
`flow namespace update`), so Namespace Files are now used for scripts that are
genuinely shared **across environments, or across more than one flow** — three
scripts so far, all under `namespace-files/shared/`: `syslogs.sh` (pulled into
`staging/backups/syslog-backup.yml` and `prod/backups/syslog-backup.yml`),
`bondlink_logs.py` (pulled into `staging/backups/bondlink-logs.yml` and
`prod/backups/bondlink-logs.yml` — its own
`ENV = "prod" if "prod" in HOSTNAME else "staging"` logic is what made it
identical between environments in the first place; it also needs `sudo` in front
of its interpreter invocation and swallows `os.unlink` exceptions in its own
cleanup step, both because it deletes files under `/var/log/bondlink`), and
`ensure_salt_perms.sh` (the getfacl/setfacl ACL fix every salt-run/salt-call flow
needs before its actual salt command — shared across all 4 such flows:
`prod/backups/saltrun-database-backups.yml`, `prod/haproxy/
saltrun-certificate-renewal.yml`, `staging/haproxy/certificate-renewal.yml`, and
`staging/suricata/suricata-update.yml`). All via
`{{ read('<file>', namespace='shared') }}` inside their heredocs, rather than being
duplicated. Everything else stays inlined per-flow for now; apply this same
`namespace-files/shared/` pattern to other scripts as they're found to be shared
across more than one flow (`delete_versions.sh` and `cert_expiration.py` are each
only used in one flow in this repo so far — not candidates yet, but worth
revisiting if a second flow reuses either). Each flow's description names the
`rundeck-jobs` source-of-truth path for anything it inlines or reads from
Namespace Files.

**Namespace Files aren't only for sharing across flows — they're also the fix
for a real production bug.** `prod/aws/clean-corp-preview-s3.yml` failed live
with `io.pebbletemplates.pebble.error.ParserException: Unclosed comment`: its
inlined script used bash's `${#keys[@]}` array-length syntax, and Kestra's
Pebble template engine parses the literal `{#` inside that as the start of a
*Pebble* comment — bash never emits a matching `#}`, so Pebble scans to
end-of-file still "inside" the comment and fails at execution time, not
authoring time. `read()`'s return value is never re-parsed for template
syntax, so moving the script to a Namespace File sidesteps the whole class of
bug rather than needing every `${#...}` occurrence escaped (fragile, easy to
reintroduce). Since this fix isn't about cross-flow sharing, these live under
`namespace-files/prod.aws/` (a per-namespace directory, not `shared/`) and are
pulled in via a bare `{{ read('<file>') }}` — no `namespace=` override needed,
since `read()` defaults to the calling flow's own namespace.
`clean-production-db-backups.yml` had the identical bug (4 occurrences) and got
the same fix pre-emptively, before it ever ran and failed the same way.
`tests/test_known_pitfalls.py::test_no_literal_pebble_comment_start` guards
against this recurring — any literal `{#` anywhere in a flow fails that test.

**Fixing the Pebble bug surfaced a second, unrelated one on the same flow**:
after the fix, `clean-corp-preview-s3.yml` still failed live with
`SSH command fails with exit status 127` (command not found) — the script,
copied verbatim from its Rundeck-era source, calls bare `aws s3 ls ...`.
Kestra's `ssh.Command` runs a non-interactive session whose PATH includes
`/usr/bin` (where bare `jq`/`nproc` resolve fine — confirmed by the log
showing the script ran past those) but not `/usr/local/bin` (where `aws` is
actually installed). Every already-working flow in this repo already used the
full `/usr/local/bin/aws` path for exactly this reason — the newly-migrated
scripts just hadn't been checked against that convention. Fixed everywhere
found, including a **pre-existing** occurrence in `dev-database-backup.yml`'s
`delete_versions.sh` heredoc that predates this session and had never been
exercised. `tests/test_known_pitfalls.py::test_ssh_command_scripts_use_full_path_for_aws_cli`
(inline flow content) and `test_namespace_file_scripts_use_full_path_for_aws_cli`
(namespace-files/**/*.sh, invisible to the flow-scoped test) both guard against
this recurring — deliberately exempting `io.kestra.plugin.aws.cli.AwsCLI` tasks,
which correctly use bare `aws` inside their own dedicated container.

**A third, unrelated bug on the same flow, found after fixing the first two**:
`clean-corp-preview-s3.yml` still failed with `SSH command fails with exit
status 127` after both fixes above. `set -x` tracing showed it died on the
very first `wait -n` call, before any background job had started — bash's own
manual says `wait -n` with zero active background jobs returns exit 127. The
script computes `parallelJobs=$((cpus / 2))` from `nproc --all`, and
`prodsalt-arm` (where this flow runs) is an `x8g.medium` — 1 vCPU — so integer
division makes `parallelJobs` 0. This is genuinely host-CPU-count-dependent:
it never surfaced under Rundeck (presumably a multi-core agent) and the script
"ran to completion" when the user pulled it to their own (multi-core) machine.
Fixed by flooring `parallelJobs` at 1 in the Namespace File — a deliberate
divergence from rundeck-jobs' source, noted in the flow's description. Not
generalized into a static test: too content-specific (the bug is about a
particular script's arithmetic, not a pattern like the others above).

Production sync (see "How flows actually get onto the production Kestra instance"
below) now runs a `namespace files update` call per `namespace-files/<namespace>/`
directory alongside its existing per-namespace `flow namespace update` loop — see
the salt repo's `salt/kestra/bin/sync-flows.sh.jinja2`. Local dev's
`ops/kestra-bootstrap.yml` mirrors this with a `io.kestra.plugin.git.
SyncNamespaceFiles` task alongside its existing `SyncFlows` task.

## Secrets this repo's flows expect

Referenced via `{{ secret('NAME') }}`, provisioned as Kestra Secrets (env vars
prefixed `SECRET_`, base64 for the SSH key):

- `SSH_PRIVATE_KEY` — the `bldeploy` key (`salt://keys/id_rsa_bldeploy` in the salt
  repo), used by every `ssh.Command` task.
- `SENDGRID_API_KEY` — used by every notification task.

In production these are populated by the salt repo's `kestra` state
(`/etc/kestra/.env`), not by anything in this repo. Local dev uses `docker-compose.yml`
+ a gitignored `.env` (see `.env.example`) with the same variable names.

## How flows actually get onto the production Kestra instance

**Not** via `ops/kestra-bootstrap.yml`'s in-flow git-sync (that's for local dev only).
Production uses a host-level `git pull` of this repo (mirroring `rundeck-jobs`' own
`sync_git.sh` + SCM-checkout pattern) followed by the Kestra CLI:

```
kestra flow namespace update <namespace> <dir> --server <url> --user=USER:PASS
```

(OSS auth is HTTP basic auth via `--user`; `--api-token` is Enterprise-only.) The
exact host-side script for this (the `sync_git.sh` equivalent) is still to be built,
on the salt side, not here.

(This paragraph originally said there was no CLI equivalent for Namespace Files —
that's no longer true, see the Namespace Files section above.)

## Tests

`tests/unit/` (pytest, see `README.md` for setup) runs static structural/policy
checks over every `flows/**/*.yml` — not real flow execution. Covers baseline
sanity (required keys, id/namespace match file path, ssh.Command connection
fields, every flow has non-empty `errors:`/`triggers:` blocks) plus the
salt-perms rule above, environment-isolation (a prod flow's `errors:` block
can't mention staging and vice versa — the exact bug clean-drone-resources.yml
had), and a grab-bag of specific bugs hit during the rollout
(`tests/unit/test_known_pitfalls.py` — bare `taskrun.value.Field`, bare `python3`
instead of the salt onedir interpreter, `namespaceFiles:` on ssh.Command,
notifications nested inside ForEach, capitalized AWS tag filter values). Wired
into CI via `.github/workflows/pytest.yml` and `.woodpecker.yml`'s
`run-unit-tests` step, runs on every PR. A separate `lint` step in
`.woodpecker.yml` (`ci/lint/lint.sh all`) runs `ruff` (Python) and `shellcheck`
(the `namespace-files/` shell scripts) as a blocking gate.

There's also one opt-in integration test
(`tests/integration/test_aws_cli_integration.py`, pytest marker `integration`,
excluded from the default run via `pytest.ini`'s `addopts`) that actually runs
every AwsCLI task's command for real against live AWS and asserts the result
isn't empty, caching results per environment/flow to show drift between runs.
Not in CI (no AWS creds there) — `make test-integration`.

## Known gaps, carried forward from the source Rundeck export (not fixed, by design)

- 5 Prod jobs were missing their `<schedule>` block in the export entirely — need
  live-Rundeck lookup before converting.
- Rundeck's weekday-number-to-cron-dow conversion (`weekday='N'`, Quartz-style SUN=1)
  is applied by best-effort assumption in every weekly flow, flagged in each one,
  never confirmed against Rundeck's live "next run" display.
- Several jobs' tag-based node filters (`corporate`, `partner`, `docker`, `cron` on
  the Staging side) don't resolve to any host in the fetched
  `s3://bondlink-rundeck/{prod,staging}.xml` inventory — flagged per-flow.
- `staging/backups/gvm-database-backup.yml` is a deliberate failing stub — its source
  script (`databases/backup_postgres_gvm.sh`) doesn't exist anywhere in `rundeck-jobs`.

## Where this stands

All Prod pilot + all Staging flows are written and committed here. Not yet loaded
into any running Kestra instance for real (local Docker testing hit a sandbox-only
Docker-in-Docker limitation — see the salt repo's debrief). The salt-side install is
validated clean end-to-end against a local test minion; **installing on the real prod
host is the next step**, at which point these flows still need the host-level
git-pull sync mechanism above actually built before they can run for real.
