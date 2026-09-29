# Staging drift check — background and open questions

The working flow is `flows/staging/infra/drift-check.yml` (`staging.infra.drift-check`). This
doc now holds only what isn't settled there — read the flow file for the actual shape.

## What it does

A nightly plan of every staging server-group directory, run on the staging Kestra worker against
its own persistent `/src/infrastructure` checkout, then a human-gated apply of whichever drifted
groups the reviewer selects.

`namespace-files/shared/tofu_drift_check.py --kestra-outputs` prints one `::{"outputs":…}::` line
(`ssh.Command` has no `outputFiles:`): `summary`, `drifted_groups`, `plans` (group → saved plan
file) and `infra_commit`. The emails embed `summary` verbatim, so no aggregate is computed inside a
Pebble template; `dev-subnet-apply.yml` uses the same line with `--group dev-subnet`.

For each drifted group the summary (and so the email) lists its saved plan file path and one line
per resource tofu would change: action plus address, e.g. `~ update aws_instance.server["x"]`,
taken from `tofu show -json`. Attribute values are deliberately left out of the email. The full
`tofu show` diff for each drifted group goes to the `drift_check` task log, which is what to read
at the `await_review` Pause.

Resuming `await_review` prompts for `groups_to_apply`, a `MULTISELECT` whose options are this run's
`drifted_groups` and whose default is empty. `apply_selected` applies only those groups, each from
its saved plan in this run, so tofu refuses a plan the state has moved past. Plans live under
`/tmp/tofu-plans/run-<execution id>/`; the `finally:` task `cleanup_plans` removes that directory
however the run ends.

## Open questions this doesn't resolve

- **`staging/db-prod-test` and `staging/ops` can be planned but not applied.** Their `backend.tf`
  sets `use_lockfile = true`, and the bucket policy lets no role write a `.tflock` object (see
  `global/iam/roles_staging_kestra_worker.tf` in `/src/infrastructure`), so an apply there fails on
  the lock. Selecting one at resume records it under `failed`.
- **With `concurrency: {limit: 1, behavior: FAIL}`, an unresumed `Pause` blocks the next night's
  scheduled run** rather than queuing or skipping it — that run fails outright on the concurrency
  conflict. Not resolved here; only matters once the trigger is un-disabled.
