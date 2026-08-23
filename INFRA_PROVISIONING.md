# Kestra-driven infra provisioning: concept and how-to

**Living document.** This was written before any of it has been exercised
for real — expect it to be wrong in places once a real `tofu apply`/highstate
run happens. Update it as flows are actually run: what the plan below got
right, what broke, what needed a different shape than described here. Don't
let it go stale as a description of intent once it diverges from what's
actually built.

**Status**: config only, nothing applied/tested against real infrastructure
yet. All three repos' work lives on `feature/kestra-infra-salt-poc`, pushed
but not merged. See "How to test this end-to-end" below for the concrete,
priority-ordered path from here to a real first run.

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

**Salt**: each worker gets `salt_minion.roles: [docker, infra-checkout,
salt-master]` — `docker` for the container runtime, `infra-checkout`
(`/src/salt/salt/infra-checkout/init.sls`, new) for a *persistent*
git-crypt-unlocked `/src/infrastructure` checkout on the host, bind-mounted
into whatever container actually runs `tofu`/`salt-call` (decrypted infra
code deliberately isn't baked into a shipped container image), and the
*lean* `salt-master` (daemon config only — **not** `salt-master-prime`,
which carries mariadb/redis/postfix/etc., a real prime-only concern; see
"Second salt-master" below).

Each worker is also registered as a **non-`prime` member of the existing
`server_group: salt-master`** pillar block in its own environment
(`/src/salt/pillar/{prod,staging}/servers/init.sls`) — for `vpc_cache`
visibility, and as the anchor for the opt-in `secondary_master` field (see
below).

### Second salt-master: what's real now, what's still open

Started from a real blocker: `get_salt_master()`
(`common/vpc_topology_macros.jinja2`) is a global lookup keyed on pillar
`prime: true` — it should keep always resolving to prime (`mysql.conf`'s
job-cache DB and Redis genuinely are singleton, prime-only resources), but
one template conflated "the canonical master address" with "my own bind
address": `salt-overrides/etc/salt/master.d/salt-api.conf`'s
`rest_cherrypy.host` was set to `{{ master_ip }}` (prime's IP) instead of
`0.0.0.0`, which only ever "worked" because on the one existing master those
two happened to be the same value. **Fixed** — `salt-api.conf` now binds
`0.0.0.0`, `salt-overrides/master.sls` dropped the `get_salt_master()`
call/context that fix made dead. That's what makes the lean `roles:salt-master`
grant above safe: a non-prime host's own salt-api now renders correctly
instead of pointing at the wrong host.

Also done — the user split `top.sls`'s old, bloated `'roles:salt-master'`
match into three: `roles:salt-api` (mariadb/mariadb-users/mariadb-grants/
bondlink-config), `roles:salt-master-prime` (postfix-relay/mailutils/redis/
google/oddjob/salt-api/suricata-update/bondlink-config — "to avoid
additional packages being installed into a kestra worker in either
environment"), and the lean `roles:salt-master` (just
`salt-overrides.master` + `salt-overrides.master-port-bridge`). Set
`salt-master`+`salt-master-prime` on `prodsalt-arm`/`stagingsalt`.
`orch/haproxy_swap_finalize.sls`'s `finalize-update-bondlink-config` target
needed updating to match (it still said `roles:salt-master`, which no
longer carries `bondlink-config` at all) — verified against the test's own
extraction logic, not guessed.

**Minion-trust mechanism — designed and implemented, not yet exercised.**
Minions resolve "the master" via one static DNS name
(`bondlink_minion.conf`'s `master: salt.<domain>`); Salt supports real
multi-master natively (`master: [...]` + `master_type: str_list` — connects
to *all* listed masters simultaneously, unlike `failover`'s one-at-a-time).
Opt-in, not fleet-wide: a new `secondary_master: <worker>` pillar field on
specific nodes only (`kestra01: secondary_master: prodkestra01`;
`ai-builds`/`develop-arm: secondary_master: stagingkestra01`) —
`salt-overrides/minion.sls` looks it up via `get_servers_config([grains['id']],
'server_name')`, and `bondlink_minion.conf` renders the `str_list` form only
when it's set, falling back to today's single-master behavior otherwise.

**Still genuinely open, not code — decisions for whoever exercises this
next:**
1. **Per-master key acceptance.** Each master keeps independent minion
   keys; no shared-PKI shortcut exists. A minion trusting `prodkestra01`
   needs its key accepted *there* too (manual `salt-key -a`, or `auto_accept:
   True` traded against relying on security-group scoping).
2. **Network reach** — confirm `kestra01`/`ai-builds`/`develop-arm` can
   actually reach their worker's 4505/4506; not checked as part of this
   work.
3. **The shared `vpc_pillar_cache_<env>` Redis key has no lock, TTL, or
   version — plain last-write-wins**, confirmed via `redis_set`'s
   implementation. `_pillar_cache_key`'s own docstring already documents
   this as a *real, previously-observed* incident ("a new server group's
   first build could not see itself and skipped its galera config"), not a
   hypothetical. This isn't new or specific to a second master — any host's
   ordinary first boot already exercises it, since `steps/70-salt-apply.sh`
   calls `vpc_cache.write_merged_cache` unconditionally. A stale, separate
   worry about this call failing on old 3007.14 minions turned out to be
   moot (the whole staging fleet has since been upgraded to 3008, and 3008's
   `pillar.get` genuinely supports the `unmask` kwarg the old code path
   lacked — verified directly against the installed 3008.0 source, not
   assumed); the leftover stale references to that non-issue were removed
   from `CLAUDE.md`, the haproxy-failover skill, and `orch/
   haproxy_swap_finalize.sls`. The *actual* race (no lock on the shared key)
   is real and still unaddressed — the better fix discussed but not yet
   built: make `vpc_cache.get_pillar_cache()` always build fresh from live
   pillar+AWS data (what `write_merged_cache()` already does) rather than
   trusting a possibly-stale Redis read, since the underlying
   `describe_instances` call is cheap (one paginated, single-VPC query) and
   was never actually a volume concern worth the persistence risk.

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

- `global/iam`/`global/s3` haven't been applied for real yet — `StagingKestraWorker`/
  `KestraWorker`'s actual AWS role/policy/instance-profile and the state-bucket
  policy extension only exist as unapplied Terraform.
- Neither worker (`prodkestra01`/`stagingkestra01`) has actually been built
  yet — `staging/ops`/`prod/ops` haven't been applied with the new server
  entries.
- **`tofu`/OpenTofu isn't installed by anything** — checked; no salt state
  installs it, and `infra-checkout` only handles the git-crypt-unlocked
  checkout, not the binary. Needs either a manual install for a first test
  or a new salt state before this is repeatable.
- **The `east`/`default` AWS CLI profiles don't exist on either worker.**
  `provider.tf` hardcodes named profiles, not the ambient instance role.
  Whether a bare `[profile east]\nregion = us-east-1` stanza (no
  credentials) resolves through to the instance's own `StagingKestraWorker`/
  `KestraWorker` role via IMDS, or needs something else, hasn't been
  verified empirically — `StagingKestraWorker`'s trust policy only trusts
  `ec2.amazonaws.com`, so a `role_arn`+`credential_source` self-assume
  approach won't work if the bare-alias approach doesn't pan out.
- `TF_VAR_aws_creation_key`/`TF_VAR_user_ssh_key` Kestra secrets don't exist
  yet.
- Security-group reach hasn't been confirmed in either direction: Kestra's
  own host (prodsalt-arm) → the relevant worker, and that worker → its
  target minion(s).
- This branch's flows aren't on the Kestra instance Kestra actually runs
  from — `kestra/init.sls`'s sync only triggers off `main`, not this feature
  branch; a pre-merge test needs a manual `kestra flow namespace update`.
- The `ai-builds` mariadb-restore example flow itself isn't built yet — the
  IAM gap that used to block it is gone now that staging's target moved to
  `dev-subnet` (which `ai-builds` is part of), but the actual flow (volume
  create/restore/remove) still needs writing on top of `shared.salt/exec.yml`.
- Second-salt-master minion trust (per-master key acceptance, network
  reach, the `vpc_cache` write race) — see "Second salt-master" above for
  what's actually open there; narrower than it used to be, but still real.

## How to test this end-to-end (priority order)

Verified against actual repo state, not assumed — a few steps below are
genuine open decisions (marked), not guesses to follow blindly.

1. **IAM first — human-run, admin credentials** (this is exactly the kind
   of change `.claude/settings.json` hard-denies for the agent):
   ```
   cd /src/infrastructure/global/iam && tofu init && tofu plan && tofu apply
   cd /src/infrastructure/global/s3   && tofu init && tofu plan && tofu apply
   ```
2. **Build `stagingkestra01`** — also human-run, chicken-and-egg (the
   worker can't provision itself before it exists). Needs
   `TF_VAR_aws_creation_key`/`TF_VAR_user_ssh_key` set and `AWS_PROFILE=east`:
   ```
   cd /src/infrastructure/staging/ops && tofu init && tofu plan && tofu apply
   ```
   Plan should show only `stagingkestra01` as new.
3. **After first boot**, SSH in and confirm `docker`/`infra-checkout`/lean
   `salt-master` actually applied, and `/etc/salt/master.d/salt-api.conf`
   renders `host: 0.0.0.0`.
4. **Close the two real gaps above manually** for this first test: install
   `tofu`, and set up/verify the `east` profile
   (`AWS_PROFILE=east aws sts get-caller-identity` should resolve to
   `StagingKestraWorker`, not error).
5. **Confirm SG reach** both directions (prodsalt-arm → `stagingkestra01`,
   `stagingkestra01` → `ai-builds.staging.vpc`).
6. **Create the two missing Kestra secrets**: `TF_AWS_CREATION_KEY`,
   `TF_USER_SSH_KEY`.
7. **Get this branch's flows onto the real Kestra instance** — merge first,
   or manually `kestra flow namespace update staging.infra <dir>` (and
   `shared.infra`, `shared.salt`) against this branch's content.
8. **Trigger `staging.infra`/`provision-server`** with its defaults
   (`server_name: ai-builds`) — `ai-builds` already exists, so the plan
   should be a no-op: a smoke test of connectivity/permissions, not a
   rebuild.
9. **Review the `tofu_plan` output at the `Pause` task** before resuming —
   confirm it's genuinely a no-op before letting `tofu_apply` run.
10. Confirm `wait_for_ssh`, the `salt_highstate` subflow's `salt-call --local
    state.apply` on `ai-builds`, and the success notification all complete.

Stop there. Don't extend to `develop-arm`, the `secondary_master`
minion-trust wiring, or anything in prod until this one path is proven.

## Where this is referenced

- `/src/infrastructure`: pointer in `global/iam/roles_kestra_worker.tf` and
  `roles_staging_kestra_worker.tf`.
- `/src/salt`: pointer in `salt/infra-checkout/init.sls`.
