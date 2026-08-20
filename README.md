# kestra-automation

## Tests

Static structural/policy checks over the flow YAML files in `flows/` — not real
flow execution (that needs a live Kestra server, or Enterprise Edition's YAML-based
Unit Tests feature, which this OSS deployment doesn't have).

```
python3 -m venv .venv
./.venv/bin/pip install -r requirements-dev.txt
./.venv/bin/pytest
```

`tests/test_flow_structure.py` covers baseline sanity: required keys, id/namespace
match their file path, ssh.Command tasks have all required connection fields, and
every flow has non-empty `errors:` and `triggers:` blocks — a flow with no known
schedule (disabled at the Rundeck source) still needs a `triggers:` block, just
with a `Schedule` trigger carrying `disabled: true` rather than omitting the block
entirely (see `wazuh-logs.yml`/`clean-drone-resources.yml`). `tests/test_salt_perms.py`
enforces one specific rule: any flow that runs salt-run/salt-call must call
`namespace-files/shared/ensure_salt_perms.sh` (via
`{{ read('ensure_salt_perms.sh', namespace='shared') }}`) before doing so — see
SESSION_DEBRIEF.md for the incident (a flow shipped without this and failed on a
salt-master ACL permissions error) that prompted the rule. `tests/test_environment_isolation.py`
catches copy/paste between environments: a prod flow's `errors:` block can't
mention staging and vice versa. `tests/test_known_pitfalls.py` is a grab-bag of
regression tests for specific bugs hit during the initial rollout (bare
`taskrun.value.Field` instead of `fromJson(taskrun.value).Field`, bare `python3`
instead of the salt onedir's interpreter, `namespaceFiles:` on an ssh.Command
task, a notification nested inside a `ForEach`, capitalized AWS tag filter
values, a literal `{#` anywhere — Pebble parses that as an unclosed comment
and fails at execution time, not authoring time — and bare `aws` invocations
in ssh.Command scripts, which need the full `/usr/local/bin/aws` path since
Kestra's non-interactive SSH session doesn't have `/usr/local/bin` on its
PATH) — each one was a real bug in a committed flow at some point, not a
hypothetical.

Runs on every PR via `.github/workflows/pytest.yml`.

### Integration test (opt-in, not gated)

`tests/test_aws_cli_integration.py` actually executes every
`io.kestra.plugin.aws.cli.AwsCLI` task's `aws` command for real, against
whatever AWS credentials/profile are active in your shell, and asserts the
result isn't empty. Not run by default and not wired into CI (no AWS
credentials configured there) — run explicitly:

```
make test-integration
```

Each flow's result is cached to `tests/integration_cache/<environment>/
<flow-id>__<task-id>.json` (gitignored — local scratch state, not a committed
baseline) so the next run prints what changed since last time (hosts
added/removed). That's diagnostic output, not a pass/fail check — live infra
drifting is expected, not a bug.
