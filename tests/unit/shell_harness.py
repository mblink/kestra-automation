"""Run the namespace-file cleanup scripts against a stubbed AWS CLI.

The rest of this suite is static checks over YAML. These scripts are the exception worth
executing: `clean_database_backups.sh` permanently deletes production database backups, and its
retention arithmetic is not something a pattern match can check. Every band boundary, every
"does a failure look like an empty bucket" question, and every "is a dry run really read-only"
question needs the script to actually run.

Nothing here touches AWS. `AWS_BIN` points the script at a stub that answers from canned fixtures
and records what it was asked to delete.
"""
import json
import os
import shutil
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PRUNER = REPO_ROOT / "namespace-files" / "prod.aws" / "clean_database_backups.sh"

# A lifecycle config that satisfies the precondition for --mode marker.
REAPING_LIFECYCLE = {
    "Rules": [
        {
            "ID": "reap",
            "Status": "Enabled",
            "Filter": {"Prefix": "backups/mysql"},
            "NoncurrentVersionExpiration": {"NoncurrentDays": 1},
            "Expiration": {"ExpiredObjectDeleteMarker": True},
        }
    ]
}

AWS_STUB = r"""#!/bin/bash
# Records every invocation, answers reads from fixtures, and refuses to be surprised.
printf '%s\n' "$*" >> "$CALLS"
case "$1 $2" in
  "s3 ls")
    if [ -n "$LS_FAILS" ]; then echo "stub: listing failed" >&2; exit 1; fi
    cat "$LISTING"
    ;;
  "s3 rm")
    shift; printf 'RM %s\n' "$*" >> "$DELETES"
    ;;
  "s3api get-bucket-lifecycle-configuration")
    cat "$LIFECYCLE"
    ;;
  "s3api list-object-versions")
    # Answer per --prefix, not one canned response for every call: a stub that ignores the
    # prefix cannot tell "deleted the right key" from "deleted the wrong one", which is the
    # only thing a version-mode test is for.
    prefix=
    while [ $# -gt 0 ]; do
      case "$1" in --prefix) prefix="$2"; shift 2 ;; *) shift ;; esac
    done
    if [ -f "$VERSIONS_DIR/$(printf '%s' "$prefix" | tr '/' '_')" ]; then
      cat "$VERSIONS_DIR/$(printf '%s' "$prefix" | tr '/' '_')"
    else
      cat "$VERSIONS_DIR/__default__"
    fi
    ;;
  "s3api delete-objects")
    printf 'DELETE_OBJECTS\n' >> "$DELETES"
    echo '{"Deleted":[],"Errors":[]}'
    ;;
  *)
    echo "stub: unhandled: $*" >&2; exit 64
    ;;
esac
"""

# Two jobs. GNU date, because the script uses `date -d` and BSD date reads -d as something else
# entirely, so a macOS run would compute different bands rather than fail. And a fixed "today", so
# the bands are the same on every run -- the boundary cases below depend on knowing exactly where
# END_WEEKLY falls, which drifts daily otherwise.
DATE_SHIM = """#!/bin/bash
if [ -n "$FAKE_TODAY" ] && [ "$1" = "+%Y-%m-%d" ]; then echo "$FAKE_TODAY"; exit 0; fi
exec {gnu_date} "$@"
"""


def _write_exec(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(0o755)


def run_pruner(tmp_path, listing, *args, lifecycle=REAPING_LIFECYCLE, versions=None,
               ls_fails=False, env=None):
    """Run the pruner with a stubbed AWS CLI. Returns (returncode, output, deletions)."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    calls, deletes = tmp_path / "calls", tmp_path / "deletes"
    calls.touch()
    deletes.touch()

    listing_file = tmp_path / "listing"
    # `aws s3 ls` renders a prefix and an object differently, and the pruner reads both with one
    # `awk '{ print $NF }'`. Rendering an object key as a PRE line would hide a future change to
    # that parse, so the shape here follows the trailing slash the way the real CLI does.
    listing_file.write_text(
        "".join(
            f"                           PRE {k}\n"
            if k.endswith("/")
            else f"2026-09-11 07:38:35   15032385536 {k}\n"
            for k in listing
        )
    )
    lifecycle_file = tmp_path / "lifecycle"
    lifecycle_file.write_text(json.dumps(lifecycle))
    # `versions` is either one response used for every prefix, or a {prefix: response} map
    # so a test can assert which keys a version-mode delete actually reaches.
    versions_dir = tmp_path / "versions"
    versions_dir.mkdir(exist_ok=True)
    empty = {"Versions": [], "DeleteMarkers": []}
    if isinstance(versions, dict) and not ({"Versions", "DeleteMarkers"} & set(versions)):
        (versions_dir / "__default__").write_text(json.dumps(empty))
        for prefix, response in versions.items():
            (versions_dir / prefix.replace("/", "_")).write_text(json.dumps(response))
    else:
        (versions_dir / "__default__").write_text(json.dumps(versions or empty))

    _write_exec(bin_dir / "aws", AWS_STUB)

    gnu_date = shutil.which("gdate") or "/bin/date"
    _write_exec(bin_dir / "date", DATE_SHIM.format(gnu_date=gnu_date))

    child_env = {
        **os.environ,
        "AWS_BIN": str(bin_dir / "aws"),
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "CALLS": str(calls),
        "DELETES": str(deletes),
        "LISTING": str(listing_file),
        "LIFECYCLE": str(lifecycle_file),
        "VERSIONS_DIR": str(versions_dir),
        "LS_FAILS": "1" if ls_fails else "",
        "FAKE_TODAY": "",
        **(env or {}),
    }
    proc = subprocess.run(
        ["bash", str(PRUNER), *args],
        capture_output=True, text=True, env=child_env, timeout=60, check=False,
    )
    return proc.returncode, proc.stdout + proc.stderr, deletes.read_text().splitlines()


def banded(tmp_path, listing, *extra, **kw):
    return run_pruner(
        tmp_path, listing,
        "--bucket", "bondlink-data-east",
        "--prefix", "backups/mysql/bondlink-us-east-1",
        "--retain", "banded", "--mode", "marker", *extra, **kw
    )
