---
name: scoped-aws-credentials
description: Mint the narrowest AWS credential a task actually needs — read-only by default — instead of letting an agent session run as your read-write IAM user, and prove the scoping holds before relying on it. Use before ANY agent AWS access here: `make test-integration`, re-running an AwsCLI task's `describe-instances` by hand, listing a backup prefix, dry-running `clean_database_backups.sh`, an investigation, a one-off write. Covers why the sandbox does not confine `aws`, which reads cannot be scoped at all, the packed-policy budget that binds long before the documented one, and why IAM refuses these credentials.
---

# Least-privilege AWS credentials for an agent session

**Mint a per-task credential, read-only by default.** The flows here delete backups (`clean_database_backups.sh --live`, `s3api delete-objects`), `s3 rm`/`sync` log archives and run `salt-run` against production. A session that can only read cannot cause an incident by misreading a bucket, a prefix or an environment. Read-only is almost always enough; if a write is needed, re-mint — it costs seconds and the widening stays visible.

## Run it

```bash
# Read-only, no S3 object reads, one hour — the default. Covers make test-integration.
.claude/skills/scoped-aws-credentials/mint-token.sh --verify
. ~/.aws/agent-readonly.env

# Reading one backup prefix's objects, and nothing else in S3.
.claude/skills/scoped-aws-credentials/mint-token.sh --read-bucket 'bondlink-data-east/backups/mysql/*' --verify

# One write, conditioned on the Environment tag.
.claude/skills/scoped-aws-credentials/mint-token.sh --env staging --allow ec2:CreateTags --verify

# Reaching a host = root command execution on every staging instance.
.claude/skills/scoped-aws-credentials/mint-token.sh --env staging --ssm-run --verify
```

- Other flags: `--read-s3 <ARN>`, `--hours` (1–36), `--out`, `--name`, `--region`, `--print-policy` (show, don't mint).
- The output file (mode 600: three `export`s + `unset AWS_PROFILE`) is sourced, never `cat`/`echo`ed: secrets must not reach argv (visible to `ps`, shell history), logs or the session transcript.
- Only the mint needs `dangerouslyDisableSandbox` (it writes under `~/.aws`); the token works sandboxed (`*.amazonaws.com` is in `.claude/settings.json`'s allowed domains).
- Before anything else, `aws sts get-caller-identity` must show `federated-user/agent-*`, not `user/<you>`.

## Why the ambient credentials are wrong

The sandbox does not confine `aws`: sandboxed, `aws sts get-caller-identity` returns your read-write IAM user. `.claude/settings.json` denies a few destructive `aws s3`/`s3api` spellings and `--live` runs of the cleanup scripts, but any other mutating call goes through. The credential is the only real narrowing.

## What this repo reaches, and what each needs

| Caller | Runs as | Calls | Token needed |
|---|---|---|---|
| `AwsCLI` tasks (`discover_*_hosts`) | prodsalt-arm's instance role in Kestra | `ec2 describe-instances` only | default |
| `make test-integration` | **you** — runs every AwsCLI task's `commands` locally, verbatim, via `bash -c` | same `describe-instances` | default |
| `namespace-files/shared/aws_query.sh` | target host's instance role | `ec2 describe-instances` | default |
| `clean_database_backups.sh` (dry run) | target host's role | `s3api get-bucket-lifecycle-configuration`, `list-object-versions` | default (bucket reads and lists are not object reads) |
| `clean_database_backups.sh --live`, `syslogs.sh`, `bondlink_logs.py`, `s3 sync`/`rm` in flows | target host's role | object writes/deletes on `bondlink-data`, `bondlink-data-east`, `bondlink-data-ohio` | never from an agent — run the flow |

- `make test-integration` passes the task text to bash unrendered, so a task whose `commands` contains Pebble (`{{ read('aws_query.sh', …) }}` in `staging/haproxy/certificate-renewal.yml`) writes that literal into the script and fails regardless of credentials.
- Locally `aws` is not at `/usr/local/bin/aws` on Apple-silicon Homebrew (`/opt/homebrew/bin/aws`). The namespace-file scripts hardcode that path for the remote hosts; `clean_database_backups.sh` takes `AWS_BIN=$(command -v aws)` to run it locally.
- No script or test here names an AWS profile, so everything takes the ambient credential chain and honours the token. A hardcoded profile would outrank it and authenticate as you.

## How the token is built

`sts:GetFederationToken` from your IAM user; effective permissions = your policy ∩ session policy, so it can never exceed you.

- Reads: AWS-managed `ReadOnlyAccess` via `--policy-arns` (works despite the docs saying same-account).
- Guardrails and widenings: the inline `--policy`, kept small. It denies all S3 object reads except what `--read-bucket`/`--read-s3` names, denies `secretsmanager:GetSecretValue`/`kms:Decrypt`/`ssm:GetParameter*`, and denies minting a wider token.

## Reads are account-wide

Most read actions take no resource-level permissions: `ec2:DescribeInstances`, `cloudwatch:Describe*`/`List*`, `logs:Describe*`, `route53:List*`/`Get*` (prod DNS included), `ssm:DescribeInstanceInformation`. **Prod metadata, DNS and SSM inventory are readable with any token** — never claim otherwise.

S3 objects are the exception: `ReadOnlyAccess` grants `s3:Get*` on everything, and the buckets these flows write hold weblogs and database dumps with real member data. Hence the default deny. Check the managed policy rather than assuming:

```bash
aws iam get-policy-version --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess \
  --version-id "$(aws iam get-policy --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess \
    --query Policy.DefaultVersionId --output text)" --query PolicyVersion.Document
```

**The buckets are not all in one region** (`bondlink-data` is us-west-2; `bondlink-data-east` us-east-1). An s3api call against the wrong region fails like a denial, so `--verify` resolves each bucket's region. For which bucket and prefix actually holds a given backup, see `s3-backup-layout`.

## The binding budget is `PackedPolicySize`

The documented 2048-character `--policy` limit is not what binds: AWS packs inline policy + managed ARNs together and reports `PackedPolicySize` (%). Each managed ARN costs ~5% (`ReadOnlyAccess` alone ≈ 7%), each inline character ~0.1%, non-linearly; 1534 inline characters was rejected (`PackedPolicyTooLarge`, 131%). Read the figure the script prints on every mint; each `--read-bucket` adds inline text, so a long prefix list hits this first.

## IAM refuses these credentials

Any IAM call returns `InvalidClientTokenId` (not `AccessDenied`) — a property of federation tokens, regardless of policy. For an IAM read, use your own credentials, read-only.

## `--verify`

Each probe row states the expected result and is marked `ok` or `MISMATCH`; read the mismatches.

- The control rows read the first object in `bondlink-data-east` and `bondlink-data`; expect `denied` unless you granted that bucket.
- The mutation pair is meaningful only when a write was granted: with no `--allow`, both rows are `UnauthorizedOperation`. With `ec2:CreateTags` on `Environment=staging`, expect `DryRunOperation` (staging) vs `UnauthorizedOperation` (prod).
- `DryRunOperation` means the call would have succeeded; both outcomes exit non-zero.

## Widening

1. Name the exact action (`ec2:CreateTags`, never `ec2:*`).
2. Add it with `--env` (conditions on the `Environment` tag). An action without resource-level permissions can't be granted this way — it fails closed; don't work around it.
3. Re-run `--verify` and read the mutation pair.
4. Don't make a broad Allow "safe" with a tag-conditioned Deny: prod resources aren't reliably tagged, so untagged prod stays writable.

`--ssm-run` grants `ssm:SendCommand` on `AWS-RunShellScript` only, not `ssm:StartSession`. The script refuses prod-mutating tokens (exit 77): prod writes are a human's decision — stop and ask.
