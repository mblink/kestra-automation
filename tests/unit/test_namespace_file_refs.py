"""Every read('<file>') in a flow must name a namespace file git tracks.

Production sync uploads namespace-files/<ns>/ from a host `git pull`, so a file
that exists only in a working tree is never uploaded, and the flow fails at
render time with FileNotFoundException under Kestra's /app/storage/.
"""
import re
import subprocess

from tests.unit.conftest import REPO_ROOT, iter_strings

READ_CALL = re.compile(
    r"""\bread\(\s*['"]([^'"]+)['"]\s*(?:,\s*namespace\s*=\s*['"]([^'"]+)['"]\s*)?\)"""
)
TRACKED = set(
    subprocess.run(
        ["git", "ls-files", "--", "namespace-files"],
        cwd=REPO_ROOT, capture_output=True, text=True, check=True,
    ).stdout.splitlines()
)


def test_read_targets_are_tracked_namespace_files(flow, flow_path):
    for value in iter_strings(flow):
        for name, namespace in READ_CALL.findall(value):
            ns = namespace or flow["namespace"]
            path = f"namespace-files/{ns}/{name}"
            assert path in TRACKED, (
                f"{flow_path}: read('{name}') resolves to {path}, which git "
                f"does not track - production sync will not upload it"
            )
