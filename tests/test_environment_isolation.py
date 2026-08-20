"""Catches copy/paste errors between environments: a prod flow's errors: block
should never mention staging, and a staging flow's errors: block should never
mention prod. This is exactly the bug clean-drone-resources.yml (flows/prod/
security/) had - a notify_success subject of "Kestra[staging_cron] Clean Drone
Resources Success" copy-pasted from a staging flow.

Scoped specifically to the errors: block (not the whole file) since flows
legitimately cross-reference the other environment elsewhere - e.g. a
description explaining a pattern shared with the flow's staging/prod
counterpart, or SESSION_DEBRIEF.md links. The errors: block is pure boilerplate
per flow, so any such reference there is always a mistake.
"""
from conftest import REPO_ROOT, iter_strings

FORBIDDEN_BY_TOP_DIR = {
    "prod": "staging",
    "staging": "prod",
}


def test_errors_block_does_not_reference_the_other_environment(flow, flow_path):
    top_dir = flow_path.relative_to(REPO_ROOT / "flows").parts[0]
    forbidden = FORBIDDEN_BY_TOP_DIR.get(top_dir)
    if forbidden is None:
        return

    errors_block = flow.get("errors")
    if not errors_block:
        return

    for value in iter_strings(errors_block):
        assert forbidden.lower() not in value.lower(), (
            f"{flow_path}: errors: block references '{forbidden}' - looks like "
            f"a copy/paste from the other environment (found in: {value!r})"
        )
