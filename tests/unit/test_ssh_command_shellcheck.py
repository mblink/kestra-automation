"""Contract tests for ci/lint/check_ssh_commands.py.

The gate lints the shell inside ssh.Command `commands:` blocks, which no other
linter reads. These pin the two properties that decide whether it catches
anything: that it finds real defects, and that it refuses rather than passes
when its own extraction breaks.
"""
import subprocess
import sys
from pathlib import Path

import pytest

from tests.unit.conftest import REPO_ROOT

CHECKER = REPO_ROOT / "ci" / "lint" / "check_ssh_commands.py"


def run(root=None):
    cmd = [sys.executable, str(CHECKER)]
    if root:
        cmd += ["--root", str(root)]
    return subprocess.run(cmd, cwd=root or REPO_ROOT, capture_output=True, text=True)


def test_repo_is_clean():
    r = run()
    assert r.returncode == 0, f"ssh.Command blocks have findings:\n{r.stdout}"


def test_it_examined_something():
    # A gate that resolves no blocks reports no findings, which is
    # indistinguishable from a clean repo. The checker must say what it read.
    r = run()
    assert "ssh.Command block(s) checked" in r.stderr
    n = int(r.stderr.split(" ssh.Command")[0].strip().split()[-1])
    assert n > 0, "extractor resolved zero blocks"


@pytest.mark.parametrize(
    "snippet,rule",
    [
        # The bug this gate exists for: $HOSTNAME is empty under the zsh that
        # ssh.Command actually invokes, so every host wrote one S3 key.
        ('/usr/local/bin/aws s3 sync /var/log/x/ "s3://b/p/$HOSTNAME/"', "SC3028"),
        ("sudo docker rmi $(sudo docker images -q)", "SC2046"),
        ("[[ -d /tmp ]] && echo yes", "SC3010"),
    ],
)
def test_catches_known_defects(tmp_path, snippet, rule):
    # Negative control: build a flow carrying the defect and confirm the gate
    # names it. Without this, test_repo_is_clean passing proves nothing.
    flow = tmp_path / "flows" / "prod" / "probe"
    flow.mkdir(parents=True)
    (flow / "probe.yml").write_text(
        "id: probe\nnamespace: prod.probe\ntasks:\n"
        "  - id: t\n    type: io.kestra.plugin.fs.ssh.Command\n"
        "    commands:\n      - |\n        set -e\n        " + snippet + "\n"
    )
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "-A"], cwd=tmp_path, check=True)
    r = run(root=tmp_path)
    assert r.returncode == 1, f"gate passed a known defect:\n{r.stdout}{r.stderr}"
    assert rule in r.stdout, f"expected {rule}, got:\n{r.stdout}"
