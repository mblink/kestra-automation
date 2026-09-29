"""Unit tests for namespace-files/shared/tofu_drift_check.py's report shaping."""
import importlib.util

from tests.unit.conftest import REPO_ROOT

SPEC = importlib.util.spec_from_file_location(
    "tofu_drift_check", REPO_ROOT / "namespace-files" / "shared" / "tofu_drift_check.py"
)
drift = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(drift)


def change(address, *actions):
    return {"address": address, "change": {"actions": list(actions)}}


def test_planned_changes_lists_actions_and_skips_no_ops():
    plan = {"resource_changes": [
        change('aws_instance.server["utilweb01"]', "update"),
        change("aws_eip.ip", "no-op"),
        change("aws_instance.db", "delete", "create"),
        change("aws_route53_record.a", "create"),
    ]}
    assert drift.planned_changes(plan) == [
        '~ update aws_instance.server["utilweb01"]',
        "-/+ replace aws_instance.db",
        "+ create aws_route53_record.a",
    ]


def test_planned_changes_reports_output_only_drift():
    plan = {"resource_changes": [change("aws_eip.ip", "no-op")],
            "output_changes": {"ip": {"actions": ["update"]}}}
    assert drift.planned_changes(plan) == ["(output changes only)"]


RESULTS = [
    {"group": "haproxy", "status": "clean"},
    {"group": "util_hosts", "status": "drift", "plan_file": "/tmp/p/util.plan",
     "changes": ["~ update aws_instance.util"]},
]


def test_summary_names_plan_file_and_changes():
    lines = drift.summary_text("staging", RESULTS).splitlines()
    assert lines[1] == "clean=1 drift=1 error=0 skipped=0"
    assert lines[2] == "DRIFT: util_hosts"
    assert lines[4:] == ["util_hosts: /tmp/p/util.plan", "  ~ update aws_instance.util"]


def test_kestra_outputs_map_each_drifted_group_to_its_plan():
    out = drift.kestra_outputs("staging", RESULTS, "abc123 subject")
    assert out["drifted_groups"] == ["util_hosts"]
    assert out["plans"] == {"util_hosts": "/tmp/p/util.plan"}
    assert out["infra_commit"] == "abc123 subject"
    assert out["summary"] == drift.summary_text("staging", RESULTS)
