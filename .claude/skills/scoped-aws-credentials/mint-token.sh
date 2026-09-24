#!/usr/bin/env bash
# Mint a least-privilege, short-lived AWS credential for an agent session.
#
#   mint-token.sh [--hours N] [--out FILE] [--name NAME] [--region R]
#                 [--read-bucket BUCKET[/PREFIX]]... [--read-s3 ARN]...
#                 [--env ENV] [--allow ACTION]... [--ssm-run]
#                 [--print-policy] [--verify]
#
# With no widening flags: read-only account-wide, every S3 object read denied.
# Each widening flag is one deliberate step away from that. Writes are always
# conditioned on aws:ResourceTag/Environment, so they need --env.
#
# Writes export lines to FILE (mode 600). Source the file; never echo it.
set -euo pipefail

READONLY_ARN="arn:aws:iam::aws:policy/ReadOnlyAccess"

HOURS=1
NAME=""
OUT=""
REGION="us-east-1"
ENVIRONMENT=""
SSM_RUN=0
VERIFY=0
PRINT_POLICY=0
PROD_WRITE_OK=0
# Parallel arrays rather than an associative one: this has to run under macOS's
# bash 3.2 as well as CI's bash 5.
READ_OBJECTS=()
PROBE_BUCKETS=()
PROBE_PREFIXES=()
ALLOW_ACTIONS=()

# Control buckets for --verify: two the flows here actually write, so their rows say
# something. bondlink-data-east holds the weblog, syslog and mariadb backups;
# bondlink-data holds the older copies. Neither is granted by default, so both
# should read `denied` on a token that named neither.
CONTROL_BUCKETS="bondlink-data-east bondlink-data"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --env) ENVIRONMENT="$2"; shift 2 ;;
    --read-bucket)
      # `bondlink-data` means the whole bucket; `bondlink-data-east/weblogs/prod/*`
      # means that prefix. Both become one object ARN.
      case "$2" in
        */*) spec="$2" ;;
        *) spec="$2/*" ;;
      esac
      READ_OBJECTS[${#READ_OBJECTS[@]}]="arn:aws:s3:::${spec}"
      PROBE_BUCKETS[${#PROBE_BUCKETS[@]}]="${spec%%/*}"
      probe_prefix="${spec#*/}"
      PROBE_PREFIXES[${#PROBE_PREFIXES[@]}]="${probe_prefix%\*}"
      unset spec probe_prefix
      shift 2 ;;
    --read-s3) READ_OBJECTS[${#READ_OBJECTS[@]}]="$2"; shift 2 ;;
    --allow) ALLOW_ACTIONS[${#ALLOW_ACTIONS[@]}]="$2"; shift 2 ;;
    --ssm-run) SSM_RUN=1; shift ;;
    --print-policy) PRINT_POLICY=1; shift ;;
    --verify) VERIFY=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 64 ;;
  esac
done

case "$HOURS" in ''|*[!0-9]*) echo "--hours takes a whole number" >&2; exit 64 ;; esac
if [ "$HOURS" -lt 1 ] || [ "$HOURS" -gt 36 ]; then
  echo "--hours must be 1-36 (GetFederationToken's own range)" >&2
  exit 64
fi

WIDENED=0
[ ${#ALLOW_ACTIONS[@]} -gt 0 ] && WIDENED=1
[ "$SSM_RUN" -eq 1 ] && WIDENED=1

if [ "$WIDENED" -eq 1 ] && [ -z "$ENVIRONMENT" ]; then
  echo "--allow and --ssm-run write to real resources, so they need --env to condition on." >&2
  echo "There is no untagged-resource escape: an action that takes no resource-level" >&2
  echo "permissions cannot be granted this way at all. See SKILL.md." >&2
  exit 64
fi
if [ "$WIDENED" -eq 1 ] && [ "$ENVIRONMENT" = prod ] && [ "$PROD_WRITE_OK" -eq 0 ]; then
  echo "Refusing to mint a prod-mutating token." >&2
  echo "Prod writes are a human decision, not an agent's. Ask, then run the change" >&2
  echo "yourself -- or edit PROD_WRITE_OK in this script if you are that human." >&2
  exit 77
fi

if [ -z "$NAME" ]; then
  if [ "$WIDENED" -eq 1 ]; then NAME="agent-${ENVIRONMENT}-write"; else NAME="agent-readonly"; fi
fi
[ -n "$OUT" ] || OUT="${HOME}/.aws/${NAME}.env"

command -v jq >/dev/null 2>&1 || { echo "jq is required to build the policy" >&2; exit 1; }

# ReadOnlyAccess arrives as a managed session policy, so the whole read surface
# costs ~7% of the packed budget instead of the ~700 characters it would take to
# hand-roll. The inline policy is then only the guardrails and the widenings.
#
# What it leaves open is the reason for the first Deny: ReadOnlyAccess grants
# s3:Get*, which reads every object in the account -- including the weblog
# archives and database dumps these flows write, which carry real member data.
# Object reads are therefore denied outright unless --read-bucket / --read-s3
# names what this task needs.
#
# The second Deny is a backstop, not a fix: ReadOnlyAccess does not grant
# GetSecretValue or kms:Decrypt today, and AWS revises that policy.
# The third stops a token from minting a wider one; sts:GetCallerIdentity is
# deliberately absent from it, since it is how you confirm which identity you
# are running as.
build_policy() {
  local statements
  statements="$(
    if [ ${#READ_OBJECTS[@]} -eq 0 ]; then
      jq -nc '[{Effect:"Deny",Action:["s3:GetObject","s3:GetObjectVersion"],Resource:"*"}]'
    else
      printf '%s\n' "${READ_OBJECTS[@]}" |
        jq -Rnc '[{Effect:"Deny",Action:["s3:GetObject","s3:GetObjectVersion"],NotResource:[inputs]}]'
    fi
  )"
  statements="$(jq -nc --argjson s "$statements" '$s + [
    {Effect:"Deny",Action:["secretsmanager:GetSecretValue","kms:Decrypt","ssm:GetParameter*"],Resource:"*"},
    {Effect:"Deny",Action:["sts:AssumeRole*","sts:GetFederationToken","sts:GetSessionToken"],Resource:"*"}
  ]')"

  if [ ${#ALLOW_ACTIONS[@]} -gt 0 ]; then
    statements="$(printf '%s\n' "${ALLOW_ACTIONS[@]}" |
      jq -Rnc --argjson s "$statements" --arg env "$ENVIRONMENT" '$s + [{
        Effect:"Allow", Action:[inputs], Resource:"*",
        Condition:{StringEquals:{"aws:ResourceTag/Environment":$env}}
      }]')"
  fi
  if [ "$SSM_RUN" -eq 1 ]; then
    # Two statements because SendCommand authorizes the document and the target
    # separately, and SSM tests its own condition key rather than aws:ResourceTag.
    statements="$(jq -nc --argjson s "$statements" --arg env "$ENVIRONMENT" '$s + [
      {Effect:"Allow",Action:"ssm:SendCommand",Resource:"arn:aws:ssm:*::document/AWS-RunShellScript"},
      {Effect:"Allow",Action:"ssm:SendCommand",Resource:"arn:aws:ec2:*:*:instance/*",
       Condition:{StringEquals:{"ssm:resourceTag/Environment":$env}}}
    ]')"
  fi
  jq -nc --argjson s "$statements" '{Version:"2012-10-17",Statement:$s}'
}

POLICY="$(build_policy)"

if [ "$PRINT_POLICY" -eq 1 ]; then
  printf '%s\n' "$POLICY" | jq .
  echo "managed session policy: ${READONLY_ARN}" >&2
  exit 0
fi

describe_scope() {
  echo "  reads      account-wide (ReadOnlyAccess), minus S3 objects and secret values"
  if [ ${#READ_OBJECTS[@]} -eq 0 ]; then
    echo "  S3 objects none"
  else
    printf '  S3 objects %s\n' "${READ_OBJECTS[0]}"
    local i=1
    while [ "$i" -lt ${#READ_OBJECTS[@]} ]; do
      printf '             %s\n' "${READ_OBJECTS[$i]}"
      i=$(( i + 1 ))
    done
  fi
  if [ ${#ALLOW_ACTIONS[@]} -eq 0 ] && [ "$SSM_RUN" -eq 0 ]; then
    echo "  writes     none"
  else
    [ ${#ALLOW_ACTIONS[@]} -eq 0 ] ||
      printf '  writes     %s on Environment=%s\n' "$(printf '%s ' "${ALLOW_ACTIONS[@]}")" "$ENVIRONMENT"
    [ "$SSM_RUN" -eq 0 ] ||
      printf '  writes     ssm:SendCommand AWS-RunShellScript on Environment=%s (root shell on those hosts)\n' "$ENVIRONMENT"
  fi
}

echo "Minting ${HOURS}h federation token '${NAME}' in ${REGION}:"
describe_scope

ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT
# Credentials and stderr are captured separately so a failure can be printed
# without any chance of the success path echoing a secret.
if ! CREDS="$(aws sts get-federation-token \
    --name "$NAME" \
    --policy "$POLICY" \
    --policy-arns "arn=${READONLY_ARN}" \
    --duration-seconds "$(( HOURS * 3600 ))" \
    --region "$REGION" \
    --query '[Credentials.AccessKeyId,Credentials.SecretAccessKey,Credentials.SessionToken,Credentials.Expiration,PackedPolicySize]' \
    --output text 2>"$ERR")"; then
  cat "$ERR" >&2
  if grep -q PackedPolicyTooLarge "$ERR"; then
    echo >&2
    echo "The packed budget binds long before --policy's documented 2048 characters." >&2
    echo "Drop a widening, or move a read surface to --policy-arns. See SKILL.md." >&2
  fi
  exit 1
fi

IFS=$'\t' read -r AK SK ST EXPIRES PACKED <<<"$CREDS"
if [ -z "${ST:-}" ]; then
  echo "get-federation-token returned no session token" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
# Created at 0600 before anything is written: a `>` redirect keeps whatever mode
# an existing file has, and a chmod afterwards is both too late for the window
# in between and skipped entirely if the write fails.
install -m 600 /dev/null "$OUT"
{
  printf 'export AWS_ACCESS_KEY_ID=%s\n' "$AK"
  printf 'export AWS_SECRET_ACCESS_KEY=%s\n' "$SK"
  printf 'export AWS_SESSION_TOKEN=%s\n' "$ST"
  printf 'unset AWS_PROFILE\n'
} > "$OUT"
unset AK SK ST CREDS

echo "Wrote ${OUT} (mode 600), expires ${EXPIRES}, packed policy ${PACKED}% of budget"
echo "Use it with:  . ${OUT}"

[ "$VERIFY" -eq 1 ] || exit 0

echo
echo "--- probes, run under the new token ---"
(
  set +u
  # shellcheck disable=SC1090
  . "$OUT"

  # Every probe captures output first. The AWS CLI exits non-zero for a
  # permitted dry run and for a denial alike, so an uncaptured call would take
  # the subshell down under `set -e` and the rest would silently not run.
  run() { "$@" 2>&1 || true; }
  code() {
    grep -oE 'DryRunOperation|UnauthorizedOperation|AccessDenied|InvalidClientTokenId|CommandId' <<<"$1" |
      head -1 || true
  }
  # Never a blank result column: a blank one reads as a probe that passed.
  report() {
    local got="${2:-UNEXPECTED}" want="$3" mark
    if [ "$got" = "$want" ]; then mark="ok"; else mark="MISMATCH"; fi
    printf '  %-42s %-18s want %-18s %s\n' "$1" "$got" "$want" "$mark"
  }

  # --output text prints the literal None for a query matching nothing, and a
  # denied call is indistinguishable from an empty result, so both become "".
  first_instance() {
    local out
    out="$(run aws ec2 describe-instances \
      --filters "Name=tag:Environment,Values=$1" Name=instance-state-name,Values=running \
      --query 'Reservations[0].Instances[0].InstanceId' --output text --region "$REGION")"
    case "$out" in None|*rror*|"") printf '' ;; *) printf '%s' "$out" ;; esac
  }
  # The buckets are not all in one region -- the legacy bondlink-data lives in
  # us-west-2 -- and an s3api call against the wrong region fails in a way that
  # looks exactly like a denial, so resolve it rather than assuming $REGION.
  bucket_region() {
    local out
    out="$(run aws s3api get-bucket-location --bucket "$1" --query LocationConstraint --output text)"
    case "$out" in
      None|null|"") printf 'us-east-1' ;;
      *rror*|*Denied*|*' '*) printf '%s' "$REGION" ;;
      *) printf '%s' "$out" ;;
    esac
  }
  first_key() {
    local out
    # --max-keys, not --max-items: the latter is CLI-side pagination and appends
    # a NextToken line, so the captured key gains a trailing "None".
    out="$(run aws s3api list-objects-v2 --bucket "$1" --prefix "$2" \
      --max-keys 1 --query 'Contents[0].Key' --output text --region "$3")"
    case "$out" in None|*rror*|"") printf '' ;; *) printf '%s' "$out" ;; esac
  }
  # Does --read-bucket / --read-s3 cover this exact key?
  key_allowed() {
    local arn="arn:aws:s3:::$1/$2" o
    for o in ${READ_OBJECTS[@]+"${READ_OBJECTS[@]}"}; do
      case "$o" in
        *\*) case "$arn" in "${o%\*}"*) return 0 ;; esac ;;
        *) [ "$arn" = "$o" ] && return 0 ;;
      esac
    done
    return 1
  }
  probe_object() {
    local label="$1" bucket="$2" prefix="$3" key want out region
    region="$(bucket_region "$bucket")"
    key="$(first_key "$bucket" "$prefix" "$region")"
    if [ -z "$key" ]; then report "$label" "no key listed" "a key"; return; fi
    if key_allowed "$bucket" "$key"; then want=readable; else want=denied; fi
    out="$(run aws s3api head-object --bucket "$bucket" --key "$key" --region "$region")"
    # A HEAD carries no error body, so a denial arrives as a bare 403 rather than
    # the AccessDenied string every other API returns.
    case "$out" in
      *ContentLength*|*LastModified*) report "$label" readable "$want" ;;
      *AccessDenied*|*"(403)"*|*Forbidden*) report "$label" denied "$want" ;;
      *) report "$label" UNEXPECTED "$want" ;;
    esac
  }

  identity="$(run aws sts get-caller-identity --query Arn --output text)"
  case "$identity" in
    *"federated-user/${NAME}") report "identity" "federated-user/${NAME}" "federated-user/${NAME}" ;;
    *) report "identity" "$identity" "federated-user/${NAME}" ;;
  esac

  # Account-wide by construction: describes take no resource-level permissions, so
  # this only asks whether reads work at all.
  n="$(run aws ec2 describe-instances --query 'length(Reservations)' --output text --region "$REGION")"
  case "$n" in
    ''|*[!0-9]*) report "read: describe-instances" "no count" "a count >0" ;;
    0) report "read: describe-instances" "count=0" "a count >0" ;;
    *) report "read: describe-instances" "a count >0" "a count >0" ;;
  esac

  # One row per granted prefix -- the grant is only proven by reading inside it.
  i=0
  while [ "$i" -lt ${#PROBE_BUCKETS[@]} ]; do
    probe_object "read: granted ${PROBE_BUCKETS[$i]}/${PROBE_PREFIXES[$i]}" \
      "${PROBE_BUCKETS[$i]}" "${PROBE_PREFIXES[$i]}"
    i=$(( i + 1 ))
  done
  # Controls: whatever object happens to sit first in each bucket, whose
  # expectation follows from the grants rather than from the bucket name.
  for b in $CONTROL_BUCKETS; do
    probe_object "read: an object in ${b}" "$b" ""
  done

  # The pair that actually proves a boundary: the same mutation against the
  # in-scope environment and against another one. With no --allow, both are
  # UnauthorizedOperation and the pair proves only that nothing can mutate.
  tag_allowed=0
  for a in ${ALLOW_ACTIONS[@]+"${ALLOW_ACTIONS[@]}"}; do
    case "$a" in ec2:CreateTags|ec2:*\*) tag_allowed=1 ;; esac
  done
  for e in staging prod; do
    id="$(first_instance "$e")"
    want=UnauthorizedOperation
    if [ "$tag_allowed" -eq 1 ] && [ "$e" = "$ENVIRONMENT" ]; then want=DryRunOperation; fi
    if [ -z "$id" ]; then
      report "write: tag a ${e} instance" "no instance" "$want"
    else
      # --dry-run: AWS evaluates permissions and mutates nothing.
      report "write: tag a ${e} instance" \
        "$(code "$(run aws ec2 create-tags --dry-run --resources "$id" \
            --tags Key=ScopeProbe,Value=1 --region "$REGION")")" "$want"
    fi
  done

  if [ "$SSM_RUN" -eq 1 ]; then
    for e in staging prod; do
      id="$(first_instance "$e")"
      if [ "$e" = "$ENVIRONMENT" ]; then want=CommandId; else want=AccessDenied; fi
      if [ -z "$id" ]; then
        report "write: ssm run on ${e}" "no instance" "$want"
      else
        report "write: ssm run on ${e}" \
          "$(code "$(run aws ssm send-command --instance-ids "$id" \
              --document-name AWS-RunShellScript --parameters 'commands=echo scope-probe' \
              --region "$REGION")")" "$want"
      fi
    done
  fi

  report "iam list-users" "$(code "$(run aws iam list-users --max-items 1)")" InvalidClientTokenId
)

cat <<'LEGEND'

Reading the table: every row states what the minted policy should produce, so a
MISMATCH is the only thing worth looking at. Two rows need context.

The describe row says only that reads work. It is not scoped to an environment
and cannot be: most read actions take no resource-level permissions, so prod
metadata, DNS and SSM inventory are readable by any token that can read at all.
S3 objects are the exception, which is what the object rows track.

The two write rows are informative only once something was granted. With no
--allow they are both UnauthorizedOperation because nothing may mutate anywhere,
which says nothing about whether an environment boundary holds; grant one action
on Environment=<env> and the in-scope/out-of-scope split is the proof.

iam list-users fails with InvalidClientTokenId rather than AccessDenied because
IAM refuses credentials from get-federation-token outright. That is a property of
the credential type, not of this policy, and it holds for actions the policy
allows.
LEGEND
