"""Only the flows listed here may run `tofu apply`.

Plan-only flows (drift-check) share scripts and boilerplate with the apply flows, so an apply
could arrive by copy/paste. Adding a flow to this list is the deliberate step.
"""
import re
import subprocess

from tests.unit.conftest import REPO_ROOT, discover_flow_paths, iter_strings, load_flow

APPLY_FLOWS = {
    "flows/shared/infra/provision-server.yml",
    "flows/staging/infra/dev-subnet-apply.yml",
    "flows/staging/infra/provision-dummy.yml",
}
SHELL_APPLY = re.compile(r"\btofu\s+apply\b")
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
