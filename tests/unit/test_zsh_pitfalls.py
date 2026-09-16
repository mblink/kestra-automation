"""Contract tests for ci/lint/check_zsh_pitfalls.py.

The gate exists because `clean-production-db-backups` shipped a `status=0`
accumulator and failed every scheduled run: `status` is read-only in zsh, which is
the shell ssh.Command actually invokes. Nothing else in the toolchain catches it --
`status=0` is valid sh and valid bash, so shellcheck passes it, and it is valid
*syntax*, so `zsh -n` passes it too.

These pin the three properties that decide whether the gate is worth having: that it
finds the real defect, that it does not fire on bash living legitimately inside a
quoted heredoc, and that it refuses rather than passes when its extraction breaks.
"""
import subprocess
import sys

import pytest

from tests.unit.conftest import REPO_ROOT

CHECKER = REPO_ROOT / "ci" / "lint" / "check_zsh_pitfalls.py"


def run(root=None):
    cmd = [sys.executable, str(CHECKER)]
    if root:
        cmd += ["--root", str(root)]
    return subprocess.run(cmd, cwd=root or REPO_ROOT, capture_output=True, text=True,
                          check=False)


def probe_repo(tmp_path, block):
    """A throwaway repo holding one flow whose ssh.Command carries `block`."""
    flow = tmp_path / "flows" / "prod" / "probe"
    flow.mkdir(parents=True)
    body = "\n".join(f"        {line}" for line in block.strip("\n").split("\n"))
    (flow / "probe.yml").write_text(
        "id: probe\nnamespace: prod.probe\ntasks:\n"
        "  - id: t\n    type: io.kestra.plugin.fs.ssh.Command\n"
        "    commands:\n      - |\n" + body + "\n"
    )
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "-A"], cwd=tmp_path, check=True)
    return tmp_path


def test_repo_is_clean():
    r = run()
    assert r.returncode == 0, f"ssh.Command blocks have zsh hazards:\n{r.stdout}"


def test_it_examined_something():
    # A gate that resolves no blocks reports no findings, which is
    # indistinguishable from a clean repo. The checker must say what it read.
    r = run()
    assert "ssh.Command block(s) checked" in r.stderr
    n = int(r.stderr.split(" ssh.Command")[0].strip().split()[-1])
    assert n > 0, "extractor resolved zero blocks"


@pytest.mark.parametrize(
    "snippet,expected",
    [
        # The incident itself, in both the declaring and the accumulating position.
        ("status=0", "read-only parameter 'status'"),
        ("/tmp/x.sh --live || status=1", "read-only parameter 'status'"),
        # Assigning a tied array is worse than an error: it silently rewrites PATH,
        # and every later command dies with the 127 the repo already fights.
        ("path=(/usr/local/bin)", "tied array 'path'"),
        ("LINENO=1", "read-only parameter 'LINENO'"),
        # Hard failures: zsh rejects these outright.
        ('echo "${host,,}"', "case-modification expansion"),
        ("shopt -s nullglob", "bash builtin 'shopt'"),
        # Silent failures: zsh leaves these empty rather than erroring.
        ('echo "${PIPESTATUS[0]}"', "bash-only variable 'PIPESTATUS'"),
        ('echo "${hosts[0]}"', "subscripts array 'hosts' at index 0"),
    ],
)
def test_catches_known_hazards(tmp_path, snippet, expected):
    # Negative control: without this, test_repo_is_clean passing proves nothing.
    r = run(root=probe_repo(tmp_path, "set -e\n" + snippet))
    assert r.returncode == 1, f"gate passed a known hazard:\n{r.stdout}{r.stderr}"
    assert expected in r.stdout, f"expected {expected!r}, got:\n{r.stdout}"


def test_quoted_heredoc_body_is_not_scanned(tmp_path):
    # The single most likely false positive. A quoted heredoc's body is inert text to
    # zsh -- it is written to a file and run later under its own `#!/usr/bin/env bash`
    # shebang -- so bash syntax is CORRECT there. Flagging it would push authors to
    # "fix" working scripts, or to silence the gate entirely.
    r = run(root=probe_repo(tmp_path, """
set -e
cat > /tmp/x.sh <<'SCRIPT'
#!/usr/bin/env bash
status=0
path=/usr/local/bin
echo "${v,,} ${BASH_SOURCE[0]} ${arr[0]}"
shopt -s nullglob
SCRIPT
chmod +x /tmp/x.sh
/tmp/x.sh
"""))
    assert r.returncode == 0, f"gate fired inside a quoted heredoc:\n{r.stdout}"


def test_unquoted_heredoc_body_is_scanned(tmp_path):
    # The converse: an UNQUOTED heredoc is expanded by zsh before it is written, so
    # its body is in scope and must stay in scope.
    r = run(root=probe_repo(tmp_path, """
set -e
cat > /tmp/x.sh <<SCRIPT
echo "${PIPESTATUS[0]}"
SCRIPT
"""))
    assert r.returncode == 1, f"gate skipped an unquoted heredoc:\n{r.stdout}"


def test_comments_naming_a_parameter_do_not_fire(tmp_path):
    # These blocks are heavily commented, and the most natural comment to write next to
    # the fix names the thing it is warning about. A gate that trips on its own
    # explanation gets switched off rather than obeyed.
    r = run(root=probe_repo(tmp_path, """
set -e
# name it rc, not status=0, because status is read-only in zsh
rc=0
/tmp/x.sh || rc=1          # path= would clobber PATH here too
exit "$rc"
"""))
    assert r.returncode == 0, f"gate fired on a comment:\n{r.stdout}"


def test_hash_inside_an_expansion_is_not_a_comment(tmp_path):
    # The comment strip must not treat $# or ${#a} as opening a comment, or it would
    # blind the gate to everything after them on the line.
    r = run(root=probe_repo(tmp_path, 'set -e\n[ $# -gt 0 ] && status=1\n'))
    assert r.returncode == 1, f"comment strip swallowed real code:\n{r.stdout}"


@pytest.mark.parametrize("delim", ["EOF-1", "E.O.F", "CLEAN_DB_BACKUPS_SCRIPT"])
def test_heredoc_delimiters_with_punctuation(tmp_path, delim):
    # A delimiter the regex does not recognise leaves the body in scope, and a bash body
    # scanned as zsh is a wall of false positives.
    r = run(root=probe_repo(tmp_path, f"""
set -e
cat > /tmp/x.sh <<'{delim}'
status=0
echo "${{v,,}}"
{delim}
/tmp/x.sh
"""))
    assert r.returncode == 0, f"delimiter {delim!r} not recognised:\n{r.stdout}"


def test_refuses_when_it_resolves_nothing(tmp_path):
    # A resolver failure must be fatal, not a silent pass -- the same rule
    # ci/lint/lint.sh applies to its own file lists.
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    r = run(root=tmp_path)
    assert r.returncode == 2, f"gate passed having checked nothing:\n{r.stderr}"


def test_does_not_fire_on_lookalikes(tmp_path):
    # Precision check. These merely contain the flagged names; none is an assignment
    # to a zsh special parameter, and a gate that cries wolf here gets switched off.
    r = run(root=probe_repo(tmp_path, """
set -e
exit_status=0
/tmp/x.sh --status=ok || exit_status=1
echo "$exit_status" > /var/run/status
echo "${hosts[1]}"
exit "$exit_status"
"""))
    assert r.returncode == 0, f"false positive on lookalikes:\n{r.stdout}"
