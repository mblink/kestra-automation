---
name: s3-backup-layout
description: Find historical logs and database backups in S3 when the prefix has changed. Use before concluding a host's logs are missing, before writing a script that globs a backup prefix, and before deleting anything under weblogs/, syslogs/ or backups/mysql/ — a server appears under two or three different names depending on the era, and weblogs use two incompatible layouts.
---

# Where the backups actually are

A host's history spans several prefixes (one layout change, two renames, plus bug-created prefixes); searching one spelling returns a partial answer that looks like data loss. Ranges below are from bucket listings of `bondlink-data`, `bondlink-data-east`, `bondlink-data-ohio` taken 2026-09-11 — re-measure if precision matters.

## weblogs/ has two overlapping layouts

| layout | span | example |
|---|---|---|
| `weblogs/<server>/<yyyy-MM>/` | 2016-10 .. 2025-01 | `weblogs/prodweb01/2019-03/` |
| `weblogs/<env>/<server>/<yyyy-MM>/` | 2020-10 .. present | `weblogs/prod/prodweb01/2024-06/` |

`<env>` is `prod` or `staging`. The two overlap for years, so reading only the newer path (as `bondlink.git scala-scripts/run interleave-logs` and oddjob's log tooling do) truncates history at each server's switch month. `syslogs/`, `ossec-logs/`, `suricata-logs/` are always `<prefix>/<server>/<yyyy-MM>/`.

## A server appears under several names

| generation | example | when |
|---|---|---|
| bare | `prodweb01` | 2018-08 onward |
| `a` suffix | `prodweb01a` | 2018-10 onward — concurrent with bare for years |
| `-arm` suffix | `prodweb01-arm` | 2026-08 onward (arm64 migration) |

E.g. `prodweb01` weblogs: `weblogs/prodweb01/` (2016-10..2023-05), `weblogs/prod/prodweb01/` (2023-04..2025-01), `weblogs/prod/prodweb01a/` (2025-01..2026-08), `weblogs/prod/prodweb01-arm/` (2026-08..).

Chains from `syslogs/`:

| host | chain |
|---|---|
| salt master | `prodsalt01` → `prodsalt02` → `prodsalt` → `prodsalt-arm` |
| staging salt | `stagingsalt01` → `stagingsalt02` → `stagingsalt` → `stagingsalt-arm` |
| staging jump | `stagingjump01` → `stagingjump` → `stagingjump-arm` |
| CI | `proddrone` → `proddrone-server` → `prodwoodpecker`; agents `proddroneagent01-03` → `04-06` → `prodwoodpeckeragent01` |
| ops | `prodops01` → `prodops02` → `prodops03` |
| monitor | `prodmon` / `prodmonitor01` → `prodmonitor` |
| analytics DB | `proddbanalytics` / `proddbanalytics01` / `proddbanalytics01a` — all three carry data |
| blog | `prodblog01` → `prodblog` |
| west replica | `prodwestdbslave` → `prodwestdbreplica` |

## `backups/mysql/` series (`<cluster>-<region>`)

| series | span |
|---|---|
| `bondlink-us-west-2` | 2018-12 .. 2024-02 (original) |
| `bondlink-us-east-1` | 2019-12 .. present (current prod OLTP) |
| `bondlink-us-east-2` | 2024-02 .. 2026-03 (Ohio era) |
| `analytics-us-east-1` | 2024-09 .. present |
| `prodmonitor-us-east-1` | 2024-10 .. 2025-02 |
| `wordpress-us-east-1` | 2022-11 .. 2023-02 |
| `binlogs/<host>/` | per host, host naming as above |

Staging has two spellings — `bondlink-staging-us-east-1` (2026-05..06) and `staging-bondlink-us-east-1` (2026-09..); match both.

## Bug-created prefixes (not real series)

| prefix | cause |
|---|---|
| `backups/mysql/None-us-east-1` | null cluster name |
| `backups/mysql/bondlink--us-east-1` | empty segment |
| `backups/mysql/bondlink-test` | leftover test run |
| `syslogs/prodweb0420` | mistyped hostname |
| `weblogs/prodjobsold` | manual rename |
| `suricata-logs//` | empty `$HOSTNAME` under zsh: every host collided on one key per date, so it holds one current capture per day and the rest as noncurrent versions. Fixed in kestra-automation#11 (OPS-123); the history stays collapsed |

## Before concluding anything is missing

```bash
aws s3 ls s3://bondlink-data-ohio/weblogs/ --recursive | grep prodweb01 | head
aws s3api list-objects-v2 --bucket bondlink-data-ohio --region us-east-2 \
  --prefix weblogs/ --query 'Contents[?contains(Key, `prodweb01`)].Key' --output text
```

- Match the **bare stem** (`prodweb01` finds `prodweb01a` and `prodweb01-arm`; the reverse doesn't).
- `bondlink-data-ohio` is entirely `GLACIER`: listed but unreadable without a restore; `CopyObject` fails `InvalidObjectState`; the console can make a prefix look empty.
- `CopyObject` caps at 5 GiB; `aws s3 cp` falls back to multipart, but S3 Batch Operations' `S3PutObjectCopy` fails `InvalidRequest` above it.
