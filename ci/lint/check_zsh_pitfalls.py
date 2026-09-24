#!/usr/bin/env python3
"""Flag zsh-specific hazards in the shell inside ssh.Command `commands:` blocks.

`ci/lint/check_ssh_commands.py` checks those blocks as /bin/sh, which catches
non-portable *syntax*. It cannot catch this class: zsh's special parameters. The
incident that prompted this gate is `clean-production-db-backups`, which shipped a
`status=0` accumulator. `status` is a read-only alias for $? in zsh -- bldeploy's
login shell, which is what ssh.Command invokes -- so the assignment failed instantly
and `set -e` aborted the task before a single prefix was pruned. Both shellcheck
(`status=0` is valid sh AND valid bash) and `zsh -n` (it is valid *syntax*; it fails
at runtime) return clean on it, so only a deny-list catches it.

Every rule below was verified against a real zsh before being encoded -- see the
`why` text on each. Constructs that merely *look* bash-only were checked and left
out: `declare -A` and a top-level `local` both work in zsh, and ZSH_VERSION,
USERNAME, pipestatus and signals are all assignable.

Scope is the inline block only. A quoted heredoc's body is inert text to zsh and is
executed later by its own shebang (these flows use `#!/usr/bin/env bash`), so those
bodies are blanked before scanning -- bash syntax is correct there, not a defect.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

import yaml

SSH_COMMAND = "io.kestra.plugin.fs.ssh.Command"
# Pebble is evaluated before the shell ever sees the text, so it is not shell. Newlines
# are preserved so reported line numbers stay true.
PEBBLE = re.compile(r"\{\{.*?\}\}", re.DOTALL)
# Quoted heredoc: <<'EOF' / <<-"EOF". Only the quoted form is inert -- an unquoted
# heredoc is still expanded by zsh, so it is deliberately left in scope.
HEREDOC = re.compile(r"<<-?\s*(['\"])([\w.-]+)\1")

# Assignment to NAME, excluding `NAME==`, a `--NAME=` flag, and a path ending in NAME.
def assign(names):
    return re.compile(r"(?<![\w/.$-])(" + "|".join(names) + r")=(?!=)")


RULES = [
    (
        assign(["status", "PPID", "ZSH_SUBSHELL", "ARGC", "HISTCMD", "LINENO",
                "zsh_eval_context", "UID", "EUID", "GID", "EGID"]),
        "assigns the zsh read-only parameter '<NAME>'",
        ("zsh aborts the command with 'read-only variable' (UID/EUID/GID/EGID fail as "
         "'failed to change user ID'); under set -e the whole task dies. Use a "
         "different name, e.g. rc."),
    ),
    (
        assign(["path", "cdpath", "fpath", "manpath", "module_path"]),
        "assigns the zsh tied array '<NAME>'",
        ("zsh ties it to the uppercase scalar, so this silently overwrites $<UPPER> "
         "for the rest of the task -- assigning path= destroys PATH and every later "
         "command fails with exit 127."),
    ),
    (
        re.compile(r"\$\{[A-Za-z_]\w*(?:\[[^\]]*\])?(,,|\^\^)"),
        "uses the bash case-modification expansion '<NAME>'",
        ("zsh has no such expansion and fails the command with 'bad substitution'. "
         "Use tr, or ${(L)var}/${(U)var}."),
    ),
    (
        re.compile(r"(?<![\w-])shopt(?![\w-])"),
        "calls the bash builtin 'shopt'",
        "zsh has no shopt; the command exits 127 with 'command not found'. Use setopt.",
    ),
    (
        re.compile(r"\$\{?(BASH_SOURCE|BASH_VERSION|BASH_REMATCH|FUNCNAME|PIPESTATUS)\b"),
        "reads the bash-only variable '<NAME>'",
        ("zsh never sets it, so it expands to the empty string silently -- no error, "
         "just wrong behaviour. (zsh spells PIPESTATUS as lowercase pipestatus.)"),
    ),
    (
        re.compile(r"\$\{?([A-Za-z_]\w*)\[0\]"),
        "subscripts array '<NAME>' at index 0",
        ("zsh arrays are 1-indexed, so [0] is silently empty. Use [1], or set "
         "KSH_ARRAYS."),
    ),
]


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


def blank_heredocs(text):
    """Replace quoted-heredoc bodies with empty lines, preserving line numbering."""
    lines = text.split("\n")
    out = []
    delimiter = None
    for line in lines:
        if delimiter is None:
            out.append(line)
            m = HEREDOC.search(line)
            if m:
                delimiter = m.group(2)
        else:
            out.append("")
            if line.strip() == delimiter:
                delimiter = None
    return "\n".join(out)


def fill(text, name):
    """Substitute plainly, not with str.format: the `why` texts quote shell syntax
    such as ${(L)var}, which format() would read as a field name."""
    return text.replace("<NAME>", name).replace("<UPPER>", name.upper())


def strip_comment(line):
    """Drop a trailing unquoted `#` comment.

    Not a shell lexer -- just enough that prose naming a flagged parameter does not fail
    the gate. These blocks are heavily commented, and a gate that trips on its own
    explanation ("name it rc, not status=0") gets switched off rather than obeyed. A `#`
    only opens a comment at the start of a word, so $# and ${#a} are untouched.
    """
    in_single = in_double = False
    for i, ch in enumerate(line):
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double and (i == 0 or line[i - 1].isspace()):
            return line[:i]
    return line


def scan(body):
    """Yield (lineno, message) for each hazard in an already-sanitized block."""
    for lineno, raw in enumerate(body.split("\n"), start=1):
        line = strip_comment(raw)
        for pattern, what, why in RULES:
            for m in pattern.finditer(line):
                name = next((g for g in m.groups() if g), m.group(0))
                yield lineno, fill(what, name) + " -- " + fill(why, name)


def main():
    ap = argparse.ArgumentParser()
    # Defaults to this file's own repo, so a run from a nested worktree cannot sweep
    # the wrong checkout. Only the contract tests pass it.
    ap.add_argument("--root", default=None)
    args = ap.parse_args()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parents[2]
    listed = subprocess.run(
        ["git", "ls-files", "-z", "--", "flows/*.yml", "flows/*.yaml"],
        cwd=root, capture_output=True, text=True, check=False,
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
    for path, task_id, idx, cmd in blocks(paths):
        checked += 1
        body = blank_heredocs(
            PEBBLE.sub(lambda m: "__PEBBLE__" + "\n" * m.group(0).count("\n"), cmd)
        )
        for lineno, message in scan(body):
            rel = path.relative_to(root)
            print(f"{rel}: task '{task_id}' command[{idx}] line {lineno}: {message}")
            found += 1

    print(f"\n{checked} ssh.Command block(s) checked, {found} finding(s)", file=sys.stderr)
    if not checked:
        print("error: no ssh.Command blocks found -- the extractor is broken",
              file=sys.stderr)
        return 2
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
