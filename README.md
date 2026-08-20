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
salt-master ACL permissions error) that prompted the rule.

Runs on every PR via `.github/workflows/pytest.yml`.
