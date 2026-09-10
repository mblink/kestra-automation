#!/usr/bin/env python3
"""Run shellcheck over the shell inside every ssh.Command `commands:` block.

`ci/lint/lint.sh` lints `namespace-files/**/*.sh`; the shell embedded in flow YAML
reaches no linter at all, which is how `$HOSTNAME` shipped in suricata.yml and sent
three staging hosts to the single S3 prefix `suricata-logs//`.

Each block is checked as **/bin/sh**, and that choice is the whole point. The remote
shell is zsh -- bldeploy's login shell, which is what `ssh.Command` invokes -- and
shellcheck cannot check zsh at all (SC1071). POSIX mode is the useful approximation:
its SC3xxx family means "not portable", and zsh shares POSIX's gaps on exactly the
constructs at issue. `$HOSTNAME` is one (SC3028); `[[ ]]`, arrays and `local` are
others. Declaring bash instead silences all of them.
"""
import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

SSH_COMMAND = "io.kestra.plugin.fs.ssh.Command"
# Pebble is evaluated before the shell ever sees the text, so it is not shell and must
# not be parsed as shell. Newlines are preserved so reported line numbers stay true.
PEBBLE = re.compile(r"\{\{.*?\}\}", re.S)


def tasks(node):
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from tasks(v)
    elif isinstance(node, list):
        for v in node:
            yield from tasks(v)


def blocks(paths):
    for path in paths:
        try:
            doc = yaml.safe_load(path.read_text())
        except yaml.YAMLError as e:
            print(f"{path}: unparseable YAML: {type(e).__name__}", file=sys.stderr)
            continue
        for task in tasks(doc):
            if not isinstance(task, dict) or task.get("type") != SSH_COMMAND:
                continue
            for i, cmd in enumerate(task.get("commands") or []):
                if isinstance(cmd, str):
                    yield path, task.get("id", "?"), i, cmd


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--severity", default="warning")
    # Defaults to this file's own repo, so a run from a nested worktree cannot
    # sweep the wrong checkout. Only the contract tests pass it.
    ap.add_argument("--root", default=None)
    args = ap.parse_args()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parents[2]
    listed = subprocess.run(
        ["git", "ls-files", "-z", "--", "flows/*.yml", "flows/*.yaml"],
        cwd=root, capture_output=True, text=True,
    )
    if listed.returncode != 0:
        print("error: git ls-files failed -- gate NOT run", file=sys.stderr)
        return 2
    paths = [root / p for p in listed.stdout.split("\0") if p]
    if not paths:
        print("error: zero flow files resolved -- refusing to pass a gate that "
              "checked nothing", file=sys.stderr)
        return 2

    found = 0
    checked = 0
    with tempfile.TemporaryDirectory() as tmp:
        for path, task_id, idx, cmd in blocks(paths):
            checked += 1
            body = PEBBLE.sub(
                lambda m: "__PEBBLE__" + "\n" * m.group(0).count("\n"), cmd
            )
            snippet = Path(tmp) / f"{checked}.sh"
            snippet.write_text("#!/bin/sh\n" + body + "\n")
            out = subprocess.run(
                ["shellcheck", f"--severity={args.severity}", "-f", "gcc", str(snippet)],
                capture_output=True, text=True,
            ).stdout
            for line in out.splitlines():
                # gcc format is path:line:col: sev: message. The path is the temp
                # snippet; name the flow and task instead, and shift for the shebang.
                parts = line.split(":", 3)
                if len(parts) < 4:
                    continue
                rel = path.relative_to(root)
                lineno = int(parts[1]) - 1 if parts[1].isdigit() else parts[1]
                print(f"{rel}: task '{task_id}' command[{idx}] line {lineno}:{parts[3]}")
                found += 1

    print(f"\n{checked} ssh.Command block(s) checked, {found} finding(s)", file=sys.stderr)
    if not checked:
        print("error: no ssh.Command blocks found -- the extractor is broken",
              file=sys.stderr)
        return 2
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
