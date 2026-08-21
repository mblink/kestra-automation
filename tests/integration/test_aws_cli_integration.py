"""Opt-in integration test: actually execute every io.kestra.plugin.aws.cli.AwsCLI
task's `aws` command for real (using whatever AWS credentials/profile are active
in the current shell - the same as running `aws` directly) and assert the result
isn't empty.

NOT run by default (`make test` / plain `pytest`) - these make real, live AWS API
calls and need real credentials, unlike the rest of the suite which is pure
static YAML analysis. Run explicitly with `make test-integration` (or
`pytest -m integration -s`). Not wired into CI: GitHub Actions has no AWS
credentials configured for this repo.

Each flow's result is cached to tests/integration_cache/<environment>/<flow-id>__
<task-id>.json (gitignored - this is local scratch state for comparing your own
runs, not a committed baseline) so consecutive runs print what changed since last
time. That's diagnostic output, not a pass/fail check - live infra drifting
(a new instance, a decommissioned one) is expected, not a bug.
"""
import json
import subprocess
import tempfile
from pathlib import Path

import pytest

from tests.unit.conftest import REPO_ROOT, find_tasks_of_type

CACHE_DIR = REPO_ROOT / "tests" / "integration_cache"


def _environment_for(flow_path):
    return flow_path.relative_to(REPO_ROOT / "flows").parts[0]


def _run_aws_cli_task(task):
    """Run an AwsCLI task's commands for real in a temp working directory,
    exactly as written (including any `> file.json` redirect), then return the
    parsed content of its first declared outputFiles entry."""
    output_files = task.get("outputFiles") or []
    assert output_files, f"AwsCLI task '{task.get('id')}' has no outputFiles declared"

    script = "\n".join(task.get("commands", []))
    with tempfile.TemporaryDirectory() as tmpdir:
        result = subprocess.run(
            ["bash", "-c", script],
            cwd=tmpdir,
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, (
            f"AwsCLI task '{task.get('id')}' failed (exit {result.returncode}): "
            f"{result.stderr}"
        )
        output_path = Path(tmpdir) / output_files[0]
        assert output_path.exists(), (
            f"AwsCLI task '{task.get('id')}' did not produce {output_files[0]}"
        )
        return json.loads(output_path.read_text())


def _diff_summary(old, new):
    """A short human-readable summary of what changed between two cached
    results (typically a list of {"Name": ..., "PrivateDnsName": ...} dicts)."""
    def _key(item):
        return json.dumps(item, sort_keys=True) if isinstance(item, dict) else str(item)

    old_keys = {_key(i) for i in old} if isinstance(old, list) else set()
    new_keys = {_key(i) for i in new} if isinstance(new, list) else set()
    added = sorted(new_keys - old_keys)
    removed = sorted(old_keys - new_keys)

    lines = []
    if added:
        lines.append(f"  + {len(added)} added: {added}")
    if removed:
        lines.append(f"  - {len(removed)} removed: {removed}")
    return "\n".join(lines) if lines else "  (no change)"


@pytest.mark.integration
def test_aws_cli_command_returns_non_empty_result(flow, flow_path):
    aws_cli_tasks = list(find_tasks_of_type(flow, "io.kestra.plugin.aws.cli.AwsCLI"))
    if not aws_cli_tasks:
        pytest.skip(f"{flow_path}: no AwsCLI tasks")

    cache_dir = CACHE_DIR / _environment_for(flow_path)
    cache_dir.mkdir(parents=True, exist_ok=True)

    for task in aws_cli_tasks:
        result = _run_aws_cli_task(task)
        assert result, (
            f"{flow_path}: AwsCLI task '{task['id']}' returned an empty result"
        )

        cache_path = cache_dir / f"{flow_path.stem}__{task['id']}.json"
        if cache_path.exists():
            previous = json.loads(cache_path.read_text())
            print(f"\n{flow_path} [{task['id']}] change since last cached run:")
            print(_diff_summary(previous, result))
        else:
            count = len(result) if isinstance(result, list) else "?"
            print(f"\n{flow_path} [{task['id']}]: no prior cache ({count} item(s))")

        cache_path.write_text(json.dumps(result, indent=2, sort_keys=True))
