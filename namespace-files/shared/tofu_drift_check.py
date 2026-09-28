#!/usr/bin/env /opt/saltstack/salt/bin/python3
# Plans every non-empty server group in config/servers_<env>.yaml and reports
# drift as JSON on stdout. Progress goes to stderr so a caller that redirects
# stdout to a result file (`... > drift_results.json`) still sees per-group
# progress in the Kestra task log. See kestra-automation's
# flows/staging/infra/drift_check.md for the flow this backs.
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
  print(f'[{env}/{group}] {status} (exit {plan.returncode}) StdOut: {plan.stdout.strip()[-2000:]} StdErr: {plan.stderr.strip()[-2000:]}', file=sys.stderr)
  return {
    'group': group,
    'directory': str(directory),
    'status': status,
    'exit_code': plan.returncode,
    'plan_file': str(plan_file) if status == 'drift' else None,
    'message': plan.stderr.strip()[-2000:] if status == 'error' else None,
  }


def write_summary(summary_file: Path, env: str, results: list[dict]) -> None:
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
  summary_file.write_text('\n'.join(lines) + '\n')


def main() -> int:
  parser = argparse.ArgumentParser(description='Plan every non-empty server group for one environment and report drift as JSON.')
  parser.add_argument('--env', required=True, help='e.g. staging, prod')
  parser.add_argument('--root', required=True, type=Path, help='infrastructure repo checkout, e.g. /src/infrastructure')
  parser.add_argument('--plan-dir', required=True, type=Path, help='directory to write .plan outfiles into')
  parser.add_argument('--group', action='append', help='limit to one or more specific groups; default is every group with a non-empty servers: block')
  parser.add_argument('--summary-file', type=Path, help='optional path for a short plain-text summary, for embedding in a notification body')
  args = parser.parse_args()

  servers_yaml = args.root / 'config' / f'servers_{args.env}.yaml'
  groups = args.group or discover_groups(servers_yaml)
  if not groups:
    print(f'No server groups with a servers: block found in {servers_yaml}', file=sys.stderr)
    return 1

  results = [run_plan(args.root, args.env, group, args.plan_dir) for group in groups]
  if args.summary_file:
    write_summary(args.summary_file, args.env, results)
  print(json.dumps({
    'environment': args.env,
    'generated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'groups': results,
  }))
  return 1 if any(result['status'] == 'error' for result in results) else 0


if __name__ == '__main__':
  sys.exit(main())
