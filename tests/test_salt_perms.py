"""Enforces: any flow that runs salt-run/salt-call must call the shared
namespace-files/shared/ensure_salt_perms.sh script first, via
{{ read('ensure_salt_perms.sh', namespace='shared') }} - or the salt command fails
with a permissions error on /var/cache/salt/minion/roots/mtime_map. See
SESSION_DEBRIEF.md for the incident that prompted this rule
(saltrun-database-backups.yml shipped without the ACL fix at all).
"""
from conftest import find_tasks_of_type

SALT_MARKERS = ("salt-run", "salt-call")
PERMS_MARKER = "ensure_salt_perms.sh"


def _joined_commands(task):
    """Every commands: entry, in order, joined so position comparisons across
    separate list items still reflect actual execution order."""
    return "\n".join(task.get("commands", []))


def test_salt_run_or_salt_call_requires_ensure_salt_perms_first(flow, flow_path):
    for task in find_tasks_of_type(flow, "io.kestra.plugin.fs.ssh.Command"):
        commands = _joined_commands(task)
        salt_positions = [commands.find(m) for m in SALT_MARKERS if m in commands]
        if not salt_positions:
            continue

        assert PERMS_MARKER in commands, (
            f"{flow_path}: task '{task.get('id')}' runs salt-run/salt-call but "
            f"never calls {PERMS_MARKER} first"
        )

        perms_position = commands.find(PERMS_MARKER)
        first_salt_position = min(salt_positions)
        assert perms_position < first_salt_position, (
            f"{flow_path}: task '{task.get('id')}' calls {PERMS_MARKER} but not "
            f"before its salt-run/salt-call invocation"
        )
