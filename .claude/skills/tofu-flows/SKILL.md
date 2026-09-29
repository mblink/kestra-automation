---
name: tofu-flows
description: Build or change a Kestra flow that runs OpenTofu (plan, review, apply) against /src/infrastructure on an environment's Kestra worker. Covers the required first step (discover the worker by AWS tags and connect by PrivateDnsName), worker credentials, the shared plan script and its outputs, the review Pause, applying a saved plan, finally: cleanup, the tests that gate all of it, and which state directories can and cannot be applied. Use before writing or editing any flow that calls tofu, and before touching tofu_drift_check.py, tofu_plan_cleanup.sh or aws_query.sh.
---

# Kestra flows that run tofu

Every tofu flow SSHes to its environment's Kestra worker and runs tofu in that worker's
`/src/infrastructure` checkout. **`flows/staging/infra/dev-subnet-apply.yml` is the template** for a
single-directory plan/apply flow, and `flows/staging/infra/drift-check.yml` for a multi-group one.
Copy from those rather than from the flows that still hardcode a host (see "Current flows").

## Current flows

| Flow | Scope | Worker host | Apply |
|---|---|---|---|
| `staging.infra.drift-check` | every staging group with a `servers:` block | discovered | groups picked at resume |
| `staging.infra.dev-subnet-apply` | `staging/dev-subnet` only | discovered | after resume |
| `staging.infra.provision-dummy` (flow `disabled: true`) | `staging/kestra_dummy` | hardcoded `stagingkestra01.staging.vpc` | after resume |
| `shared.infra.provision-server` | `inputs.tf_dir` | `inputs.runner_host` | after resume, then SSH wait + `shared.salt.highstate` |
| `staging.infra.provision-server` / `prod.infra.provision-server` (both `disabled: true`) | wrappers passing `tf_dir`, `aws_profile`, `runner_host` | hardcoded `stagingkestra01.staging.vpc` / `prodkestra01.bondlink.vpc` | via the shared flow |

The hardcoded hosts are the pattern this skill replaces.

## Step 1: discover the worker — always the first task

```yaml
  - id: get_target_host
    type: io.kestra.plugin.aws.cli.AwsCLI
    outputFiles:
      - host.txt
    commands:
      - |
        set -eo pipefail
        cat > /tmp/aws_query.sh <<'AWS_QUERY_SCRIPT'
        {{ read('aws_query.sh', namespace='shared') }}
        AWS_QUERY_SCRIPT
        chmod +x /tmp/aws_query.sh
        /tmp/aws_query.sh environmentKestraWorker staging | tr -d '\n' > host.txt
        rm -f /tmp/aws_query.sh
```

Every later task that touches the worker — plan, apply, the `finally:` cleanup — uses the same
`host: "{{ read(outputs.get_target_host.outputFiles['host.txt']) }}"`. Plans are files on that one
machine, so a task pointed at any other host finds nothing.

Why an AWS lookup and not a hostname:

- The environments' private zones (`*.staging.vpc`, `*.bondlink.vpc`) resolve only inside their
  own environment, while one Kestra server opens every SSH connection, for staging and prod
  alike. An instance's AWS `PrivateDnsName` (`ip-….ec2.internal`) resolves from that server for
  either environment: drift-check and dev-subnet-apply reach the staging worker this way.
- Replacing or renaming a worker needs no flow edit, DNS record or server change: the lookup
  follows the tags.

That is why every lookup in `namespace-files/shared/aws_query.sh` returns `PrivateDnsName`, never a
`Name` tag or a private-zone name:

| Function | Matches (running instances only) | 0 matches | >1 match |
|---|---|---|---|
| `environmentKestraWorker <env>` | `tag:NodeType=kestra-worker`, `tag:Environment=<env>` | fails | first one |
| `privateDnsByTagName <Name>` | `tag:Name=<Name>` | fails | fails |

Tag values are lowercase (`staging`, `prod`), and AWS tag filters are case-sensitive.
`get_target_host` is an `AwsCLI` task, so it runs in its own container with the Kestra server's
instance-role credentials. `ssh.Command` tasks run on the worker as `bldeploy`, with the worker's
instance role.

## Step 2: credentials on the worker

The plan task, in this order:

```bash
set -e
export PATH="/usr/local/bin:$PATH"
TF_VAR_aws_creation_key=$(/usr/local/bin/aws secretsmanager get-secret-value --region us-east-1 --secret-id staging/kestra-worker/tf-aws-creation-key --query SecretString --output text)
TF_VAR_user_ssh_key=$(/usr/local/bin/aws secretsmanager get-secret-value --region us-east-1 --secret-id staging/kestra-worker/tf-user-ssh-key --query SecretString --output text)
export TF_VAR_aws_creation_key TF_VAR_user_ssh_key
cat > /tmp/kestra_aws_config <<'AWS_CONFIG'
{{ read('aws_instance_role_profiles.ini', namespace='shared') }}
AWS_CONFIG
export AWS_CONFIG_FILE=/tmp/kestra_aws_config
export AWS_PROFILE=east
```

- The two `TF_VAR_*` come from Secrets Manager with the worker's instance role, not from Kestra's
  `secret()` store. `shared.infra.provision-server` still reads `secret('TF_AWS_CREATION_KEY')` /
  `secret('TF_USER_SSH_KEY')`, which do not exist in Kestra.
- The Secrets Manager calls run before `AWS_CONFIG_FILE`/`AWS_PROFILE` are set, so they use the
  instance role directly.
- `/src/infrastructure`'s `provider.tf` hardcodes the profiles `default`, `east`, `ohio` and
  `oregon`. `aws_instance_role_profiles.ini` defines exactly those, with regions and no credentials,
  so the SDK falls through to the instance role. Without it, `tofu init` fails with
  `failed to get shared config profile, east`.
- The apply task needs only `AWS_CONFIG_FILE` and `AWS_PROFILE`: a saved plan carries its variable
  values.

## Step 3: plan with the shared script

```bash
cd /src/infrastructure
git pull
cat > /tmp/tofu_drift_check.py <<'DRIFT_SCRIPT'
{{ read('tofu_drift_check.py', namespace='shared') }}
DRIFT_SCRIPT
chmod +x /tmp/tofu_drift_check.py
/opt/saltstack/salt/bin/python3 /tmp/tofu_drift_check.py \
  --env staging --root /src/infrastructure --group dev-subnet \
  --plan-dir /tmp/tofu-plans/run-{{ execution.id }} --kestra-outputs
rm -f /tmp/tofu_drift_check.py
```

- `git pull` plans whatever branch the worker's checkout is on.
- `--group` (repeatable) limits the plan to those directories under `<root>/<env>/`. Without it,
  the script plans every group with a non-empty `servers:` block in `config/servers_<env>.yaml`.
- The plan runs with `-lock=false -detailed-exitcode`. Each group comes out `clean`, `drift`,
  `error` or `skipped`, and the script exits 1 if any group errored, which fails the task.
- The task log gets per-group progress, the infrastructure commit and, for each drifted group, the
  full `tofu show` diff. That log is what a reviewer reads before resuming.
- `--kestra-outputs` prints one `::{"outputs": …}::` line, read back as
  `outputs.<task>.vars.<key>`:

| Key | Value |
|---|---|
| `summary` | counts, drifted/errored groups, and per drifted group its plan path plus one `~ update <address>`-style line per changed resource. Addresses and actions only, no attribute values, so it is safe to email |
| `drifted_groups` | list of group names with changes |
| `plans` | map of group name to saved plan path |
| `infra_commit` | `<short sha> <subject>` of the checkout |

## Step 4: gate on changes, then pause for review

```yaml
  - id: apply_if_changed
    type: io.kestra.plugin.core.flow.If
    condition: "{{ outputs.tofu_plan.vars.drifted_groups | length > 0 }}"
    then:
      - id: notify_plan      # email: infra_commit, summary, link to the execution
      - id: review_plan
        type: io.kestra.plugin.core.flow.Pause
      - id: tofu_apply
      - id: notify_applied
    else:
      - id: notify_no_changes
```

- A bare `Pause` waits until someone resumes the execution in the UI. Nothing applies before that.
- To let the reviewer choose among several groups, give the `Pause` an `onResume` input, as
  drift-check does. Read it back as `outputs.<pause id>.onResume.<input id>`:

  ```yaml
        onResume:
          - id: groups_to_apply
            type: MULTISELECT
            expression: "{{ outputs.drift_check.vars.drifted_groups }}"
            required: false
  ```

  Nest the apply in a second `If` on `{{ outputs.<pause>.onResume.groups_to_apply | default([]) | length > 0 }}`,
  so resuming with nothing selected applies nothing.
- The execution link in emails is
  `https://kestra.prod.bondlink.org/ui/main/executions/{{ flow.namespace }}/{{ flow.id }}/{{ execution.id }}`.
  Keep that URL out of a staging flow's `errors:` block (`test_environment_isolation.py`).

## Step 5: apply the saved plan

```bash
cd /src/infrastructure/staging/dev-subnet
tofu apply -input=false -no-color "{{ outputs.tofu_plan.vars.plans['dev-subnet'] }}"
tofu output -no-color > /tmp/<name>-outputs-{{ execution.id }}.txt
```

- Applying the saved plan, never a fresh `tofu apply`, means tofu rejects the plan as stale if the
  state changed since it was made.
- Use `tofu output -no-color`, not `-json`: the text form masks sensitive outputs and JSON prints
  them in the clear. Pass the text back with a `::{"outputs": …}::` line built by
  `/opt/saltstack/salt/bin/python3 -c` and `json.dumps(dict(...))`.
- Applying several groups in one task: loop with `while read -r group plan; do … done < file`,
  over lines generated from the `| toJson` of the selection and the `plans` map (drift-check's
  `apply_selected`). Give `tofu apply` `< /dev/null` inside that loop, or it reads the rest of the
  loop's input. Record applied and failed groups, and end with `[ -z "$failed" ]` so a partial
  failure fails the task.

## Step 6: clean up in `finally:`

```yaml
finally:
  - id: cleanup_plans
    type: io.kestra.plugin.fs.ssh.Command
    host: "{{ read(outputs.get_target_host.outputFiles['host.txt']) }}"
    # port/username/authMethod/privateKey/strictHostKeyChecking as every ssh.Command
    commands:
      - |
        set -e
        cat > /tmp/tofu_plan_cleanup.sh <<'CLEANUP_SCRIPT'
        {{ read('tofu_plan_cleanup.sh', namespace='shared') }}
        CLEANUP_SCRIPT
        chmod +x /tmp/tofu_plan_cleanup.sh
        /tmp/tofu_plan_cleanup.sh {{ execution.id }}
        rm -f /tmp/tofu_plan_cleanup.sh
```

`finally:` runs when the execution succeeds, fails or is killed; a paused execution runs it once it
is resumed or killed. `tofu_plan_cleanup.sh` takes the execution id, not a path, rejects anything
that isn't `[A-Za-z0-9_-]+`, and removes only `/tmp/tofu-plans/run-<id>`. Put anything else the
apply needs, such as a selection file, inside that directory so the cleanup covers it.

## What the tests enforce

| Test | Rule |
|---|---|
| `test_tofu_apply_scope.py` | only the flows in `APPLY_FLOWS` contain `tofu apply` (outside `description:`); no tracked namespace file runs it; each apply flow writes plans only under `/tmp/tofu-plans/run-{{ execution.id }}` and runs `tofu_plan_cleanup.sh {{ execution.id }}` in `finally:` |
| `test_tofu_plan_cleanup.py` | the cleanup script's id validation, and that it removes only the run directory |
| `test_tofu_drift_check.py` | change-line format, summary layout, `kestra_outputs` keys |
| `test_namespace_file_refs.py` | every `read()` names a namespace file git tracks, which is what the sync uploads |

A new apply flow means adding its path to `APPLY_FLOWS`. That is the deliberate step.

## Where apply cannot work

- **No state lock anywhere in staging's server groups.** Groups without `use_lockfile` have no
  lock at all, so each flow's `concurrency: {limit: 1, behavior: FAIL}` is the only guard against
  two applies at once. An unresumed `Pause` holds that slot, and the next run fails on it.
- **`use_lockfile = true` groups can be planned, not applied.** The bucket policy lets no role
  write a `.tflock` object. In staging that is `app_domains`, `cloudfront`, `cw_dashboards`,
  `db-prod-test`, `integration_test`, `networking`, `nginx_s3_gateway`, `ops` and `ssm_monitor`
  (per each directory's `backend.tf`).
- **The staging worker's role can write only some state keys**: `staging/{ops,redis,databases,db-prod-test,haproxy,util_hosts,webservers,dev-subnet,kestra_dummy}/terraform.tfstate`
  (`global/iam/roles_staging_kestra_worker.tf` in `/src/infrastructure`). Anything else fails at
  apply even when the plan succeeds.

## Shell and template constraints

These apply to every `ssh.Command` block, and the linters check them (see CLAUDE.md for the full
list):

- `commands:` runs in `bldeploy`'s login shell, **zsh**. Never assign `status` (it's read-only).
  An unquoted `$var` is not split into words, so loop over lines with `while read`, not
  `for x in $var`.
- Kestra renders Pebble (`{{ }}`, `{% %}`) before the shell sees the text. `read()` output is
  inserted as-is and never rendered again, which is why scripts live in `namespace-files/` behind
  quoted heredocs.
- Use `| toJson`, not `| json`, which Kestra 2.0 removes. `ssh.Command` has no `outputFiles:`;
  pass values back with `::{"outputs": …}::` lines.
- Use `/usr/local/bin/aws` and `/opt/saltstack/salt/bin/python3`, never bare `aws` or `python3`.
