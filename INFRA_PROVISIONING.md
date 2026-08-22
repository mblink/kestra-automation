# Kestra-driven infra provisioning: concept and how-to

**Living document.** This was written before any of it has been exercised
for real — expect it to be wrong in places once a real `tofu apply`/highstate
run happens. Update it as flows are actually run: what the plan below got
right, what broke, what needed a different shape than described here. Don't
let it go stale as a description of intent once it diverges from what's
actually built.

Spans three repos: this one (`kestra-automation`), `/src/infrastructure`
(terraform/OpenTofu), and `/src/salt` (SaltStack states + pillar). This file
lives here; the other two carry a short pointer back to it rather than a
copy — see "Where this is referenced" below.

## The problem this solves

In `/src/infrastructure`, a server's `user_data` (rendered once, at
`tofu apply` time, capped at 16KB) bootstraps the instance and runs a salt
highstate exactly once, at first boot (`scripts_etc/init/runners/full-build.sh`
→ `steps/70-salt-apply.sh`). There's no Terraform provisioner, no retry, and
no way to re-apply configuration short of SSHing in by hand — a config
change that salt alone could apply in place instead requires either editing
`user_data` (which has drifted/corrupted across changes over time) and
forcing a rebuild, or manual intervention.

The fix isn't to make `user_data` smarter — it's to stop depending on it for
anything past first boot. `user_data` only ever needs to be *present and
correct once*. Everything else — reapplying config, running an ad-hoc salt
execution-module call, whatever comes next — belongs in Kestra instead,
where it's retryable, logged, and notified regardless of whether the box was
just built or has been running for a year.

## Architecture

**One dedicated worker node per environment**, not a shared/central one:
`prodkestra01` (prod) and `stagingkestra01` (staging), both defined in
`/src/infrastructure`'s `config/servers_{prod,staging}.yaml` under each
environment's `ops:` group. Each worker manages *only its own environment's*
resources — this wasn't the original design (the first pass had one
prod-hosted worker reaching across into staging) but is the current one,
arrived at because:

- Staging and prod share **one AWS account** (`668874212870` — confirmed,
  not assumed). There's no account-level isolation between them, so keeping
  each worker's reach scoped to its own environment via IAM (not network
  topology) is the only real boundary that exists.
- A worker is single-purpose by design: it runs one docker container, holds
  one scoped IAM role, and does one job. Putting it on prodsalt-arm/stagingsalt
  (the existing salt masters, which also run other things) would have meant
  inheriting a much bigger, unrelated attack surface for no benefit.

Each worker's *target* (the resources it actually manages) is a dedicated,
non-production-traffic group, not either environment's live `webservers` —
`prod/kestra` (a new, single-server group, `kestra01`) and
`staging/dev-subnet` (an existing group used for exactly this: non-prod
experimentation, currently `ai-builds`/`develop-arm`). This PoC's own
apply/highstate testing should never be able to touch real user-facing
traffic, even by accident.

**IAM**: each worker gets its own instance-role policy
(`global/iam/roles_kestra_worker.tf` for prod, `roles_staging_kestra_worker.tf`
for staging) scoped tightly to what `modules/terraform-aws-instance/main.tf`
actually creates for that environment's target group — `prod/kestra` for
prod, `staging/dev-subnet` for staging (each a dedicated, non-production-
traffic group, deliberately not either environment's live `webservers`) —
EC2/EBS
lifecycle gated by `aws:RequestTag/Environment`, `iam:PassRole` locked to the
exact instance-profile ARN that group uses (the single most dangerous
permission if left unscoped — `RunInstances` + unscoped `PassRole` is a
standard AWS privilege-escalation path), CloudWatch alarms scoped by name
prefix, Route53 scoped to the two real zone IDs, S3 scoped to exactly one
state object. Philosophy: prefer `AccessDenied` at apply time over a broad
grant "just in case" — every policy here should be expected to need
iterating on the first few real runs, not be complete on day one.

**Salt**: each worker gets `salt_minion.roles: [docker, infra-checkout]` —
`docker` for the container runtime, `infra-checkout` (`/src/salt/salt/
infra-checkout/init.sls`, new) for a *persistent* git-crypt-unlocked
`/src/infrastructure` checkout on the host, bind-mounted into whatever
container actually runs `tofu`/`salt-call` — decrypted infra code
deliberately isn't baked into a shipped container image.

Each worker is also registered as a **non-`prime` member of the existing
`server_group: salt-master`** pillar block in its own environment
(`/src/salt/pillar/{prod,staging}/servers/init.sls`) — visibility/topology
registration for `vpc_cache` only, **not** the actual salt-master daemon.
Giving a worker the `roles:saltmaster` grain today would render actively
*wrong* config, not just an unused daemon: `get_salt_master()`
(`common/vpc_topology_macros.jinja2`) and everything derived from it
(`salt-overrides/master.sls`'s `salt-api.conf`/`mysql.conf` rendering) is a
global singleton lookup keyed on pillar `prime: true` — it never resolves to
"whichever host is rendering this," so a non-prime worker's own salt-api
would try to bind to the *existing* prime master's IP, and its own
mariadb/redis installs (also pulled in by `roles:salt-master`) would sit
unused. This is a real, unresolved gap in `/src/salt` as it stands, not
something this work fixes — it's why the worker doesn't actually run a
master daemon, and why minions don't (and can't yet) accept jobs dispatched
*from* a worker. That's real follow-on salt engineering, not a Kestra
problem.

## Flow structure

- **`flows/shared/infra/provision-server.yml`** (`shared.infra`) — the
  actual sequence: `tofu plan` → `Pause` (human reviews before anything
  applies — this repo's own `.claude/settings.json` hard-denies `tofu apply`
  for the agent, a signal this should stay human-gated) → `tofu apply` →
  wait for the new/changed server's SSH to come up → `Subflow` into the
  highstate → notify. Takes real inputs (`environment`, `tf_dir`,
  `aws_profile`, `runner_host`, `server_name`, `resource_address`,
  `target_ssh_host`) so it's the same flow for both environments.
- **`flows/staging/infra/provision-server.yml`** / **`flows/prod/infra/
  provision-server.yml`** — thin, environment-specific wrapper flows. Each
  just `Subflow`-calls the shared flow above with its own worker/directory/
  profile baked in, and carries its own `concurrency: {limit: 1, behavior:
  FAIL}` (neither `staging/dev-subnet` nor `prod/kestra` has a real
  Terraform state lock — this is the only thing preventing two concurrent
  applies against the same state key). The `concurrency:` block has to live
  here, not on the shared flow, or it would serialize staging and prod
  applies against *each other*, which is wrong.
- **`flows/shared/salt/highstate.yml`** — reusable `salt-call --local
  state.apply` runner, one or more target hosts. Deliberately masterless:
  runs on the target itself, using whatever `/src/salt` branch that host was
  actually built against, not whatever's checked out on a master.
- **`flows/shared/salt/exec.yml`** — the generic sibling of `highstate.yml`,
  for one-off `salt-call --local <execution-module-function>` calls instead
  of a full `state.apply`. Same masterless reasoning. This is what a flow
  like "attach a volume, run `mariadb_backup.restore_last_backup`, detach
  the volume" would use for its middle step — SSH + `salt-call --local`, no
  master-dispatched `salt '<target>' <function>` needed, sidestepping the
  whole dual-master gap above entirely.

Why a **shared flow**, not a `namespace-files/shared/` script, for the tofu
logic specifically: this repo's established convention for cross-environment
sharing has been "extract the script, duplicate the flow" (see
`ensure_salt_perms.sh`'s four callers). That doesn't work here because
`read()`'s return value is never re-parsed for Pebble template syntax, and
the tofu commands are saturated with `{{ inputs.* }}`/`{{ secret(...) }}`/
`{% if %}` — moving them into a script would leave all of that as inert
literal text. A `Subflow`-called flow's own tasks render normally, which is
why this shape was used instead. `namespace-files/shared/` is still the
right call for anything template-free.

## How to add a new flow following this pattern

1. **Decide: state or execution module?** Reapplying/extending configuration
   → build on `shared.salt/highstate.yml`. A one-off action (restore a
   backup, run a specific module function) → build on `shared.salt/exec.yml`.
   Either way: SSH to the target itself, `salt-call --local`, never a
   master-dispatched `salt '<target>' ...` — that path doesn't work yet (see
   Architecture above).
2. **Check the worker's IAM scope.** If the flow needs to touch AWS resources
   outside what the relevant worker's role already covers (`prod/kestra` for
   `KestraWorker`, `staging/dev-subnet` for `StagingKestraWorker`), that's a
   real gap to close explicitly in `global/iam/roles_kestra_worker.tf` /
   `roles_staging_kestra_worker.tf`, not something to work around with a
   broader grant.
3. **New host, not just new logic?** It needs to exist in
   `config/servers_{prod,staging}.yaml` (Terraform side) *and* in
   `pillar/{prod,staging}/servers/init.sls` under the right `server_group`
   (Salt side, for `vpc_cache` visibility) — these are two separate,
   uncoupled files in two separate repos; adding one without the other is
   an easy, silent gap.
4. **Environment-specific or shared?** If the same logic needs to run
   against both environments, write it once as a `shared.*` flow with real
   inputs, then a thin per-environment wrapper (see `provision-server.yml`'s
   three files above) — don't duplicate the logic itself.
5. **Every flow still needs its own `triggers:`/`errors:`** blocks
   (repo policy, enforced by `tests/unit/test_flow_structure.py`) even when
   it's a thin wrapper with nothing else in it.

## Open gaps (known, not solved here)

- No apply-capable IAM identity exists yet behind the `east`/`default` AWS
  profiles `provider.tf` hardcodes — today only human admins or read-only
  CI roles are on the state bucket's `infrastructure_roles`.
- `TF_VAR_aws_creation_key`/`TF_VAR_user_ssh_key` Kestra secrets don't exist
  yet.
- Neither worker has `tofu`/`aws`/git-crypt actually installed and confirmed
  working yet — this is all still config, not a provisioned/tested reality.
- The `ai-builds` mariadb-restore example flow itself isn't built yet — the
  IAM gap that used to block it is gone now that staging's target moved to
  `dev-subnet` (which `ai-builds` is part of), but the actual flow (volume
  create/restore/remove) still needs writing on top of `shared.salt/exec.yml`.
- The real second-salt-master / minion-dual-trust work (see Architecture) —
  deliberately out of scope until `get_salt_master()` and friends are made
  render-host-relative.

## Where this is referenced

- `/src/infrastructure`: pointer in `global/iam/roles_kestra_worker.tf` and
  `roles_staging_kestra_worker.tf`.
- `/src/salt`: pointer in `salt/infra-checkout/init.sls`.
