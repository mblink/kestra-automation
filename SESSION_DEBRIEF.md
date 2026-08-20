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

- `flows/prod/{backups,haproxy,security}/` — 5 pilot flows, one per structural pattern
  found in the ~31 Prod jobs (simple exec, multi-step-collapsed-to-one-SSH-task,
  multi-host node-first, parallel/step-cron, dual onsuccess+onfailure notification).
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

`tests/` (pytest, see `README.md` for setup) runs static structural/policy checks
over every `flows/**/*.yml` — not real flow execution. Covers baseline sanity
(required keys, id/namespace match file path, ssh.Command connection fields,
every flow has non-empty `errors:`/`triggers:` blocks) plus the salt-perms rule
above. Wired into CI via `.github/workflows/pytest.yml`, runs on every PR.

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
