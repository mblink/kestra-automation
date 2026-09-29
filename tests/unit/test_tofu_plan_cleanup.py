"""namespace-files/shared/tofu_plan_cleanup.sh runs rm -rf from every plan/apply flow's finally:."""
import subprocess
import uuid
from pathlib import Path

import pytest

from tests.unit.conftest import REPO_ROOT

SCRIPT = REPO_ROOT / "namespace-files" / "shared" / "tofu_plan_cleanup.sh"


def run(*args):
    return subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True, check=False)


@pytest.mark.parametrize("bad", ["", "../staging", "a/b", "run 1", "$(id)", "x;rm"])
def test_refuses_anything_but_an_execution_id(bad):
    r = run(bad)
    assert r.returncode != 0, r.stdout
    assert "removed" not in r.stdout


def test_requires_an_argument():
    assert run().returncode != 0


def test_missing_dir_is_not_an_error():
    r = run(f"pytest-{uuid.uuid4().hex}")
    assert r.returncode == 0 and "no plans" in r.stdout


def test_removes_only_the_run_dir():
    execution_id = f"pytest-{uuid.uuid4().hex}"
    run_dir = Path(f"/tmp/tofu-plans/run-{execution_id}")
    sibling = Path(f"/tmp/tofu-plans/run-{execution_id}-other")
    try:
        (run_dir / "nested").mkdir(parents=True)
        sibling.mkdir(parents=True)
    except OSError as e:
        pytest.skip(f"/tmp/tofu-plans not writable here: {e}")
    try:
        (run_dir / "plan").write_text("x")
        (run_dir / "nested" / "g.plan").write_text("x")
        r = run(execution_id)
        assert r.returncode == 0, r.stderr
        assert not run_dir.exists()
        assert sibling.exists()
    finally:
        subprocess.run(["rm", "-rf", str(run_dir), str(sibling)], check=False)
