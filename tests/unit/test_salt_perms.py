"""Enforces: any flow that runs salt-run must call the shared
namespace-files/shared/ensure_salt_perms.sh script first, via
{{ read('ensure_salt_perms.sh', namespace='shared') }} - or the salt command fails
with a permissions error on /var/cache/salt/minion/roots/mtime_map. See
SESSION_DEBRIEF.md for the incident that prompted this rule
(saltrun-database-backups.yml shipped without the ACL fix at all).

Scoped to salt-run specifically, not salt-call or a bare `salt <target>` exec -
neither of those touches the master's mtime_map cache (salt-call --local runs
standalone on the minion; a bare `salt <target> <module>` dispatches from the
master without going through the orchestrate/state-run path that needs it), and
none of the Rundeck-source jobs using either pattern ever included the ACL fix.
"""
from tests.unit.conftest import find_tasks_of_type

SALT_MARKER = "salt-run"
PERMS_MARKER = "ensure_salt_perms.sh"


def _joined_commands(task):
    """Every commands: entry, in order, joined so position comparisons across
    separate list items still reflect actual execution order."""
    return "\n".join(task.get("commands", []))


def test_salt_run_requires_ensure_salt_perms_first(flow, flow_path):
    for task in find_tasks_of_type(flow, "io.kestra.plugin.fs.ssh.Command"):
        commands = _joined_commands(task)
        if SALT_MARKER not in commands:
            continue

        assert PERMS_MARKER in commands, (
            f"{flow_path}: task '{task.get('id')}' runs salt-run but never "
            f"calls {PERMS_MARKER} first"
        )

        perms_position = commands.find(PERMS_MARKER)
        salt_position = commands.find(SALT_MARKER)
        assert perms_position < salt_position, (
            f"{flow_path}: task '{task.get('id')}' calls {PERMS_MARKER} but not "
            f"before its salt-run invocation"
        )
