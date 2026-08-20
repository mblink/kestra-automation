"""Regression tests for specific bugs hit during the initial AWS-discovery /
namespace-files rollout - each one either surfaced as a real execution error on
the live Kestra instance, or was found reviewing a flow while fixing something
else. None of these are hypothetical: every pattern checked here was present in
a committed flow at some point and had to be fixed. See SESSION_DEBRIEF.md.
"""
import re

import pytest

from conftest import REPO_ROOT, find_tasks_of_type, iter_strings, walk

BARE_TASKRUN_FIELD_ACCESS = re.compile(r"taskrun\.value\.[A-Za-z_]")
BARE_PYTHON_INVOCATION = re.compile(r"(?<!/)\bpython3?\s+/tmp/\S+\.py\b")
BAD_SHEBANG_LINES = {"#!/usr/bin/env python3", "#!/usr/bin/env python"}
BAD_AWS_TAG_CASING = re.compile(r"Values=Staging\b|Values=Prod\b")
NOTIFICATION_TYPE_MARKER = "notifications."
BARE_AWS_INVOCATION = re.compile(r"(?:^|[|;`]|\$\()\s*aws\b")


def test_no_bare_taskrun_value_field_access(flow, flow_path):
    # taskrun.value is a JSON *string* during ForEach iteration over objects,
    # not a parsed map - `taskrun.value.PrivateDnsName` fails at execution time
    # with "Unable to find `PrivateDnsName`". Must be
    # fromJson(taskrun.value).PrivateDnsName. This regex only matches the bare
    # form: the correct form is `fromJson(taskrun.value).Field`, where
    # "taskrun.value" is followed by ")" rather than "."
    for value in iter_strings(flow):
        assert not BARE_TASKRUN_FIELD_ACCESS.search(value), (
            f"{flow_path}: bare 'taskrun.value.<field>' access found - wrap it "
            f"as fromJson(taskrun.value).<field>: {value!r}"
        )


def test_no_bare_python_interpreter_invocation(flow, flow_path):
    # These hosts have system python3 (3.12, missing boto3/more_itertools/etc.)
    # and the salt onedir's bundled python3 (3.14, where those libs actually
    # live) at /opt/saltstack/salt/bin/python3. Invoking a script as bare
    # `python3 /tmp/x.py` resolves via $PATH to the system interpreter and
    # silently ignores the script's own shebang.
    for value in iter_strings(flow):
        assert not BARE_PYTHON_INVOCATION.search(value), (
            f"{flow_path}: bare python interpreter invocation found - use "
            f"/opt/saltstack/salt/bin/python3 explicitly: {value!r}"
        )
        for line in value.splitlines():
            assert line.strip() not in BAD_SHEBANG_LINES, (
                f"{flow_path}: generic python shebang found - use "
                f"'#!/usr/bin/env /opt/saltstack/salt/bin/python3': {line!r}"
            )


def test_ssh_command_tasks_do_not_use_namespace_files_property(flow, flow_path):
    # namespaceFiles: on an ssh.Command task only stages files into the Kestra
    # worker's own local working directory - it does not upload them to the
    # remote SSH host, so referencing a namespace file this way silently does
    # nothing useful. Use {{ read('<file>', namespace='...') }} embedded in the
    # command text instead (see any discover_*_hosts flow for the pattern).
    for task in find_tasks_of_type(flow, "io.kestra.plugin.fs.ssh.Command"):
        assert "namespaceFiles" not in task, (
            f"{flow_path}: ssh.Command task '{task.get('id')}' sets "
            f"namespaceFiles:, which does not upload files to the remote host"
        )


def _iter_tasks_nested_in_foreach(node):
    """Yield every task dict that lives inside a ForEach's own tasks: list -
    i.e. runs once per iteration - anywhere in the flow."""
    if isinstance(node, dict):
        if node.get("type") == "io.kestra.plugin.core.flow.ForEach":
            for inner_task in node.get("tasks", []):
                yield from walk(inner_task)
        else:
            for value in node.values():
                yield from _iter_tasks_nested_in_foreach(value)
    elif isinstance(node, list):
        for item in node:
            yield from _iter_tasks_nested_in_foreach(item)


def test_notification_tasks_are_not_nested_inside_foreach(flow, flow_path):
    # A notification task nested inside a ForEach's tasks: fires once per
    # iteration (once per host) instead of once per execution - found in
    # clean-drone-resources.yml, where notify_success was sending one success
    # email per drone agent instead of one per run.
    for task in _iter_tasks_nested_in_foreach(flow):
        task_type = task.get("type", "")
        if NOTIFICATION_TYPE_MARKER in task_type:
            raise AssertionError(
                f"{flow_path}: notification task '{task.get('id')}' "
                f"({task_type}) is nested inside a ForEach - it will fire once "
                f"per iteration instead of once per execution. Move it to a "
                f"top-level sibling task after the ForEach."
            )


def test_ssh_command_scripts_use_full_path_for_aws_cli(flow, flow_path):
    # A real production failure: clean-corp-preview-s3.yml (copied verbatim
    # from a Rundeck-era script) invoked bare `aws s3 ls ...`, which worked
    # fine when run manually/under Rundeck but failed with "SSH command fails
    # with exit status 127" (command not found) under Kestra's non-interactive
    # ssh.Command session - /usr/local/bin isn't on that session's PATH, only
    # /usr/bin is (which is why bare `jq`/`nproc` are fine but bare `aws`
    # isn't). Every already-working flow in this repo uses the full
    # /usr/local/bin/aws path for exactly this reason. Scoped to ssh.Command
    # tasks only - io.kestra.plugin.aws.cli.AwsCLI tasks correctly use bare
    # `aws`, since they run inside their own amazon/aws-cli container where it
    # actually is on PATH (see any discover_*_hosts task).
    for task in find_tasks_of_type(flow, "io.kestra.plugin.fs.ssh.Command"):
        for command in task.get("commands", []):
            for line in command.splitlines():
                assert not BARE_AWS_INVOCATION.search(line), (
                    f"{flow_path}: ssh.Command task '{task.get('id')}' invokes "
                    f"bare `aws` - use the full /usr/local/bin/aws path: "
                    f"{line!r}"
                )


def _discover_namespace_file_scripts():
    return sorted((REPO_ROOT / "namespace-files").rglob("*.sh"))


@pytest.mark.parametrize(
    "script_path",
    _discover_namespace_file_scripts(),
    ids=lambda p: str(p.relative_to(REPO_ROOT)),
)
def test_namespace_file_scripts_use_full_path_for_aws_cli(script_path):
    # Same bug as test_ssh_command_scripts_use_full_path_for_aws_cli, but
    # scripts loaded via {{ read('<file>') }} never appear as literal text in
    # the flow YAML, so that flow-scoped test can't see them - scan the actual
    # namespace-files/**/*.sh sources directly instead.
    content = script_path.read_text()
    for line in content.splitlines():
        assert not BARE_AWS_INVOCATION.search(line), (
            f"{script_path}: invokes bare `aws` - use the full "
            f"/usr/local/bin/aws path: {line!r}"
        )


def test_aws_filters_use_correct_tag_value_casing(flow, flow_path):
    # Confirmed live against the actual AWS account: instance tags are
    # lowercase ('staging'/'prod'), and AWS filter Values= are case-sensitive,
    # so a capitalized filter value silently matches zero instances.
    for value in iter_strings(flow):
        assert not BAD_AWS_TAG_CASING.search(value), (
            f"{flow_path}: AWS filter uses capitalized tag value casing "
            f"(actual tags are lowercase): {value!r}"
        )


def test_no_literal_pebble_comment_start(flow, flow_path):
    # A real production failure: clean-corp-preview-s3.yml inlined a bash
    # script using `${#keys[@]}` (array-length syntax). Kestra's Pebble
    # template engine parses the literal `{#` inside that as the start of a
    # *Pebble* comment (`{# ... #}`); bash never emits a matching `#}`, so
    # Pebble scans to end-of-file still "inside" the comment and throws
    # `ParserException: Unclosed comment` at execution time - it doesn't fail
    # at authoring time, only when the flow actually runs. `${#array[@]}` /
    # `${#var}` (bash length syntax) are the common way this happens, but the
    # check is just for the literal substring, since that's what actually
    # breaks parsing regardless of cause. Fix: move the script to a Namespace
    # File and pull it in via read() instead of inlining it - read()'s return
    # value is never re-parsed for template syntax, so it's immune (see
    # clean-corp-preview-s3.yml / clean-production-db-backups.yml).
    #
    # Scoped to tasks/errors/triggers only, not the top-level description -
    # Kestra doesn't Pebble-render description: (every flow already uses
    # unescaped {{ }} in prose there with no issue), and several flows'
    # descriptions legitimately quote the literal '{#' characters when
    # explaining this exact bug.
    executable_content = {
        k: v for k, v in flow.items() if k in ("tasks", "errors", "triggers")
    }
    for value in iter_strings(executable_content):
        assert "{#" not in value, (
            f"{flow_path}: literal '{{#' found - Pebble will parse this as an "
            f"unclosed comment and fail at execution time. If this came from "
            f"bash's ${{#array[@]}}/${{#var}} length syntax, move the script to "
            f"a Namespace File and pull it in via read() instead of inlining "
            f"it: {value!r}"
        )
