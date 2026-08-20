"""Baseline structural sanity checks for every flow YAML file in flows/."""
from conftest import REPO_ROOT, find_tasks_of_type

REQUIRED_TOP_LEVEL_KEYS = ("id", "namespace", "tasks")
REQUIRED_SSH_COMMAND_FIELDS = {
    "host",
    "port",
    "username",
    "authMethod",
    "privateKey",
    "strictHostKeyChecking",
}


def test_flow_has_required_top_level_keys(flow, flow_path):
    for key in REQUIRED_TOP_LEVEL_KEYS:
        assert key in flow, f"{flow_path}: missing required top-level key '{key}'"


def test_flow_id_matches_filename(flow, flow_path):
    expected_id = flow_path.stem
    assert flow["id"] == expected_id, (
        f"{flow_path}: flow id '{flow['id']}' does not match filename stem "
        f"'{expected_id}'"
    )


def test_flow_namespace_matches_directory_path(flow, flow_path):
    rel_dir = flow_path.relative_to(REPO_ROOT / "flows").parent
    expected_namespace = ".".join(rel_dir.parts)
    assert flow["namespace"] == expected_namespace, (
        f"{flow_path}: namespace '{flow['namespace']}' does not match its "
        f"directory path (expected '{expected_namespace}')"
    )


def test_flow_has_at_least_one_task(flow, flow_path):
    assert flow["tasks"], f"{flow_path}: 'tasks' list is empty"


def test_flow_has_errors_and_triggers_blocks(flow, flow_path):
    # A flow that's currently disabled at the source (no known schedule to carry
    # over) still needs a triggers: block - use a Schedule trigger with
    # disabled: true rather than omitting the block entirely, so this rule has no
    # exceptions. See wazuh-logs.yml / clean-drone-resources.yml for that pattern.
    for key in ("errors", "triggers"):
        assert flow.get(key), (
            f"{flow_path}: missing or empty required top-level key '{key}'"
        )


def test_ssh_command_tasks_have_required_connection_fields(flow, flow_path):
    for task in find_tasks_of_type(flow, "io.kestra.plugin.fs.ssh.Command"):
        missing = REQUIRED_SSH_COMMAND_FIELDS - task.keys()
        assert not missing, (
            f"{flow_path}: ssh.Command task '{task.get('id')}' is missing "
            f"{missing}"
        )


def test_failure_notifications_reference_sendgrid_secret(flow, flow_path):
    for task in find_tasks_of_type(
        flow, "io.kestra.plugin.notifications.sendgrid.SendGridMailSend"
    ):
        assert "{{ secret('SENDGRID_API_KEY') }}" == task.get("sendgridApiKey"), (
            f"{flow_path}: SendGridMailSend task '{task.get('id')}' does not "
            f"reference the SENDGRID_API_KEY secret"
        )
