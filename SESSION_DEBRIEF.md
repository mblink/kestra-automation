# Session debrief: Rundeck → Kestra migration

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
`logs/` folders are **inlined directly into each flow's `commands:`** via quoted
heredocs (`<<'DELIM'`), not pulled from Kestra's Namespace Files feature — that
mechanism was tried and deliberately dropped for simplicity. Trade-off: if a shared
script changes, every flow inlining it needs a manual matching update. Each flow's
description names the `rundeck-jobs` source-of-truth path for anything it inlines.

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

There's no equivalent CLI for Namespace Files, which is one more reason inlining won.

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
