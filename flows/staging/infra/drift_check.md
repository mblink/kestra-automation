# Staging drift check — background and open questions

The working flow is `flows/staging/infra/drift-check.yml` (`staging.infra.drift-check`). This
doc now holds only what isn't settled there — read the flow file for the actual shape.

## What it does

A nightly plan-only sweep of every staging server-group directory, run from `stagingkestra01`
against its own persistent `/src/infrastructure` checkout (same assumption
`flows/shared/infra/provision-server.yml` already makes — see its "UNRESOLVED PREREQUISITES").
It reports clean/drift/error per group and pauses for human review; it never applies anything.
The post-pause step re-runs the same plan rather than doing nothing on resume.

`namespace-files/shared/tofu_drift_check.py` writes both the full JSON (`/tmp/drift_results.json`
on the worker) and a short plain-text summary (via `--summary-file`). `ssh.Command` has no
`outputFiles:`, so the task prints the summary as a `::{"outputs":{"summary":…}}::` line and the
notification embeds it verbatim with `{{ outputs.drift_check.vars.summary }}`, avoiding any need to
compute an aggregate inside a Pebble template.

For each drifted group the summary (and so the email) lists its saved plan file path and one line
per resource tofu would change: action plus address, e.g. `~ update aws_instance.server["x"]`,
taken from `tofu show -json`. Attribute values are deliberately left out of the email. The full
`tofu show` diff for each drifted group goes to the `drift_check` task log, which is what to read
at the `await_review` Pause. Kestra has no file-hosting or hyperlink mechanism for an arbitrary
path on a remote host, so the plan file's path *is* the handoff artifact a follow-up "apply this
plan" flow would take as an input.

`flows/staging/infra/provision-dummy.yml` exercises the separate, still-untested
`tofu plan -> Pause -> tofu apply` chain (`shared.infra/provision-server.yml`'s own shape)
against `staging/kestra_dummy` — a harmless `random_pet` resource — before that mechanism is
trusted against real staging infrastructure or wired up as this flow's own follow-up apply step.

## Open questions this doesn't resolve

- **How a human actually triggers the real apply for a drifted group.** A new flow taking
  `plan_file`/`group` as inputs? Given CLAUDE.md's gotcha 26 (a plan goes stale the moment another
  branch or process applies to the same directory), that follow-up flow should probably re-plan
  and diff against the saved plan rather than blindly `tofu apply <old-plan-file>` hours or days
  later — worth deciding before building it, not worth guessing here.
- **This still depends on every open gap `INFRA_PROVISIONING.md` already lists**: `tofu` isn't
  installed on `stagingkestra01` by any Salt state yet, the `east` AWS CLI profile's IMDS
  resolution through `StagingKestraWorker` hasn't been verified empirically, and
  `TF_AWS_CREATION_KEY`/`TF_USER_SSH_KEY` Kestra secrets don't exist yet. None of that is specific
  to drift-checking — it blocks `provision-server.yml` and `provision-dummy.yml` equally — but it
  means neither flow can be run for real until those are resolved.
- **Retention of `/tmp/tofu-plans/staging/*.plan` on the worker.** Nothing cleans old plan files
  up; a stale plan sitting around after its underlying resources changed is actively misleading if
  an apply flow ever reads it back without re-checking freshness (see the gotcha 26 point above).
  Worth a retention policy once the apply-side flow exists.
- **With `concurrency: {limit: 1, behavior: FAIL}`, an unresumed `Pause` blocks the next night's
  scheduled run** rather than queuing or skipping it — that run fails outright on the concurrency
  conflict. Not resolved here; only matters once the trigger is un-disabled.
