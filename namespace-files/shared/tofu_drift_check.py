#!/usr/bin/env /opt/saltstack/salt/bin/python3
# Plans every non-empty server group in config/servers_<env>.yaml (or --group) and reports drift
# on stdout: raw JSON, or with --kestra-outputs the ::{"outputs": ...}:: line an ssh.Command turns
# into outputs.<task>.vars. Progress and full plan diffs go to stderr, i.e. the Kestra task log.
# See kestra-automation's flows/staging/infra/drift_check.md.
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

import yaml


def discover_groups(servers_yaml: Path) -> list[str]:
  # Truthy check, not `is not None`: config/servers_<env>.yaml can carry a
  # `servers: {}` group (see modules/bondlink-data-instance/main.tf's own
  # `!= null` filter, which *would* include one) -- this script wants exactly
  # the "non-empty" groups asked for, so an explicitly empty block is skipped
  # rather than planned as a no-op directory.
  data = yaml.safe_load(servers_yaml.read_text())
  return sorted(key for key, value in data.items() if isinstance(value, dict) and value.get('servers'))


def run_plan(root: Path, env: str, group: str, plan_dir: Path) -> dict:
  directory = root / env / group
  if not directory.is_dir():
    print(f'[{env}/{group}] skipped: {directory} does not exist', file=sys.stderr)
    return {'group': group, 'directory': str(directory), 'status': 'skipped', 'message': 'directory not found'}

  print(f'[{env}/{group}] tofu init', file=sys.stderr)
  init = subprocess.run(
    ['tofu', 'init', '-input=false', '-no-color'],
    cwd=directory, capture_output=True, text=True, check=False,
  )
  if init.returncode != 0:
    print(f'[{env}/{group}] init failed. Return code {init.returncode}. Stderr: {init.stderr.strip()[-2000:]}', file=sys.stderr)
    return {
      'group': group, 'directory': str(directory), 'status': 'error',
      'exit_code': init.returncode, 'message': init.stderr.strip()[-2000:],
    }

  plan_dir.mkdir(parents=True, exist_ok=True)
  plan_file = plan_dir / f'{env}_{group}_{time.strftime("%Y%m%d%H%M")}.plan'
  print(f'[{env}/{group}] tofu plan -> {plan_file}', file=sys.stderr)
  # -lock=false: a plan only reads state, and several of these groups' backend.tf
  # set use_lockfile = true while no role (including this one) can write the
  # .tflock object -- see global/iam/roles_staging_kestra_worker.tf in
  # /src/infrastructure. -detailed-exitcode: 0 clean, 2 drift, anything else error.
  plan = subprocess.run(
    ['tofu', 'plan', '-input=false', '-no-color', '-lock=false', '-detailed-exitcode', f'-out={plan_file}'],
    cwd=directory, capture_output=True, text=True, check=False,
  )
  status = {0: 'clean', 2: 'drift'}.get(plan.returncode, 'error')
  print(f'[{env}/{group}] {status} (exit {plan.returncode})', file=sys.stderr)
  if status == 'error':
    print(f'[{env}/{group}] plan stderr: {plan.stderr.strip()[-2000:]}', file=sys.stderr)
  return {
    'group': group,
    'directory': str(directory),
    'status': status,
    'exit_code': plan.returncode,
    'plan_file': str(plan_file) if status == 'drift' else None,
    'changes': describe_plan(directory, env, group, plan_file) if status == 'drift' else None,
    'message': plan.stderr.strip()[-2000:] if status == 'error' else None,
  }


ACTION_LABELS = {
  ('create',): '+ create',
  ('delete',): '- delete',
  ('update',): '~ update',
  ('delete', 'create'): '-/+ replace',
  ('create', 'delete'): '+/- replace',
  ('read',): 'read',
}


def planned_changes(plan_json: dict) -> list[str]:
  # Addresses and actions only: attribute values (user_data, keys) stay out of the
  # notification email. The full diff goes to the task log via describe_plan.
  changes = []
  for change in plan_json.get('resource_changes') or []:
    actions = tuple(change['change']['actions'])
    if actions != ('no-op',):
      changes.append(f'{ACTION_LABELS.get(actions, "/".join(actions))} {change["address"]}')
  outputs = (plan_json.get('output_changes') or {}).values()
  if not changes and any(tuple(output['actions']) != ('no-op',) for output in outputs):
    changes.append('(output changes only)')
  return changes


def describe_plan(directory: Path, env: str, group: str, plan_file: Path) -> list[str]:
  shown = subprocess.run(
    ['tofu', 'show', '-no-color', str(plan_file)],
    cwd=directory, capture_output=True, text=True, check=False,
  )
  print(f'[{env}/{group}] planned changes:\n{shown.stdout.strip() or shown.stderr.strip()}', file=sys.stderr)
  shown_json = subprocess.run(
    ['tofu', 'show', '-json', str(plan_file)],
    cwd=directory, capture_output=True, text=True, check=False,
  )
  if shown_json.returncode != 0:
    return [f'(tofu show -json failed: {shown_json.stderr.strip()[-500:]})']
  return planned_changes(json.loads(shown_json.stdout))


def summary_text(env: str, results: list[dict]) -> str:
  counts = {status: 0 for status in ('clean', 'drift', 'error', 'skipped')}
  for result in results:
    counts[result['status']] += 1
  lines = [
    f'{env} drift check — {time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}',
    ' '.join(f'{status}={count}' for status, count in counts.items()),
  ]
  for status in ('drift', 'error'):
    groups = [result['group'] for result in results if result['status'] == status]
    if groups:
      lines.append(f'{status.upper()}: {", ".join(groups)}')
  for result in results:
    if result['status'] == 'drift':
      lines += ['', f'{result["group"]}: {result["plan_file"]}']
      lines += [f'  {change}' for change in result['changes']]
  return '\n'.join(lines) + '\n'


def infra_commit(root: Path) -> str:
  log = subprocess.run(
    ['git', '-C', str(root), 'log', '-1', '--format=%h %s'],
    capture_output=True, text=True, check=False,
  )
  return log.stdout.strip() or '(unknown)'


def kestra_outputs(env: str, results: list[dict], commit: str) -> dict:
  drifted = [result for result in results if result['status'] == 'drift']
  return {
    'summary': summary_text(env, results),
    'drifted_groups': [result['group'] for result in drifted],
    'plans': {result['group']: result['plan_file'] for result in drifted},
    'infra_commit': commit,
  }


def main() -> int:
  parser = argparse.ArgumentParser(description='Plan every non-empty server group for one environment and report drift as JSON.')
  parser.add_argument('--env', required=True, help='e.g. staging, prod')
  parser.add_argument('--root', required=True, type=Path, help='infrastructure repo checkout, e.g. /src/infrastructure')
  parser.add_argument('--plan-dir', required=True, type=Path, help='directory to write .plan outfiles into')
  parser.add_argument('--group', action='append', help='limit to one or more specific groups; default is every group with a non-empty servers: block')
  parser.add_argument('--kestra-outputs', action='store_true', help='print the Kestra outputs line (summary, drifted_groups, plans, infra_commit) instead of raw JSON')
  args = parser.parse_args()

  servers_yaml = args.root / 'config' / f'servers_{args.env}.yaml'
  groups = args.group or discover_groups(servers_yaml)
  if not groups:
    print(f'No server groups with a servers: block found in {servers_yaml}', file=sys.stderr)
    return 1

  commit = infra_commit(args.root)
  print(f'infrastructure at: {commit}', file=sys.stderr)
  results = [run_plan(args.root, args.env, group, args.plan_dir) for group in groups]
  if args.kestra_outputs:
    print('::' + json.dumps({'outputs': kestra_outputs(args.env, results, commit)}) + '::')
  else:
    print(json.dumps({
      'environment': args.env,
      'generated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
      'groups': results,
    }))
  return 1 if any(result['status'] == 'error' for result in results) else 0


if __name__ == '__main__':
  sys.exit(main())
