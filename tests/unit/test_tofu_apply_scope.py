"""Only the flows listed here may run `tofu apply`.

Every tofu flow shares scripts and boilerplate, so an apply could arrive in a new one by
copy/paste. Adding a flow to this list is the deliberate step.
"""
import re
import subprocess

import pytest

from tests.unit.conftest import REPO_ROOT, discover_flow_paths, iter_strings, load_flow

APPLY_FLOWS = {
    "flows/shared/infra/provision-server.yml",
    "flows/staging/infra/dev-subnet-apply.yml",
    "flows/staging/infra/drift-check.yml",
    "flows/staging/infra/provision-dummy.yml",
}
SHELL_APPLY = re.compile(r"\btofu\s+apply\b")
RUN_DIR = "/tmp/tofu-plans/run-{{ execution.id }}"
# A path token may embed a Pebble expression, which contains spaces.
PLAN_TARGET = re.compile(r"(?:-out=|--plan-dir\s+)((?:\{\{.*?\}\}|[^\s{])+)")
PYTHON_APPLY = re.compile(r"""['"]tofu['"]\s*,\s*['"]apply['"]""")


def flows_running_apply():
    for path in discover_flow_paths():
        flow = load_flow(path)
        # description: prose may mention apply; only executable fields count.
        fields = {k: v for k, v in flow.items() if k != "description"}
        if any(SHELL_APPLY.search(s) for s in iter_strings(fields)):
            yield path.relative_to(REPO_ROOT).as_posix()


def test_only_listed_flows_run_tofu_apply():
    assert set(flows_running_apply()) == APPLY_FLOWS


def test_namespace_file_scripts_never_apply():
    # Scripts are shared into plan-only flows via read(); an apply belongs in the flow itself.
    tracked = subprocess.run(
        ["git", "ls-files", "--", "namespace-files"],
        cwd=REPO_ROOT, capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    assert tracked, "no tracked namespace files - scan checked nothing"
    for rel in tracked:
        text = (REPO_ROOT / rel).read_text()
        assert not SHELL_APPLY.search(text) and not PYTHON_APPLY.search(text), f"{rel} runs tofu apply"


@pytest.mark.parametrize("rel", sorted(APPLY_FLOWS))
def test_apply_flows_keep_plans_in_the_run_dir(rel):
    # The finally: cleanup removes only RUN_DIR; a plan written anywhere else outlives the run.
    flow = load_flow(REPO_ROOT / rel)
    targets = [t for s in iter_strings(flow["tasks"]) for t in PLAN_TARGET.findall(s)]
    assert targets, f"{rel}: no -out=/--plan-dir found"
    for target in targets:
        assert target.startswith(RUN_DIR), f"{rel}: plan written to {target}, outside {RUN_DIR}"


@pytest.mark.parametrize("rel", sorted(APPLY_FLOWS))
def test_apply_flows_clean_up_plans_in_finally(rel):
    flow = load_flow(REPO_ROOT / rel)
    commands = [s for s in iter_strings(flow.get("finally") or [])]
    assert any("tofu_plan_cleanup.sh {{ execution.id }}" in c for c in commands), (
        f"{rel}: finally: must run tofu_plan_cleanup.sh {{{{ execution.id }}}}"
    )
