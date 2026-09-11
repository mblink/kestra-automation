---
name: s3-backup-layout
description: Find historical logs and database backups in S3 when the prefix has changed. Use before concluding a host's logs are missing, before writing a script that globs a backup prefix, and before deleting anything under weblogs/, syslogs/ or backups/mysql/ — a server appears under two or three different names depending on the era, and weblogs use two incompatible layouts.
---

# Where the backups actually are

A host's history is **not** under one prefix. Layouts changed once, hosts were renamed twice, and
several prefixes exist only because a script emitted an empty or null variable. A search for one
spelling silently returns a partial answer, which reads exactly like data loss.

Everything here was measured against the live bucket listings on 2026-09-11 (2,717,504 keys across
`bondlink-data`, `bondlink-data-east` and `bondlink-data-ohio`). Re-measure rather than trusting
the ranges if precision matters.

## weblogs/ has two layouts, and they overlap

| layout | span | example |
|---|---|---|
| `weblogs/<server>/<yyyy-MM>/` | 2016-10 .. 2025-01 | `weblogs/prodweb01/2019-03/` |
| `weblogs/<env>/<server>/<yyyy-MM>/` | 2020-10 .. present | `weblogs/prod/prodweb01/2024-06/` |

`<env>` is `prod` or `staging`. **The cutover is not clean** — 26 months carry both, and the old
layout kept receiving until 2025-01. Reading only the newer path, as `bondlink.git
scala-scripts/run interleave-logs` and oddjob's log tooling both do, silently truncates history at
whatever month that server switched.

`syslogs/`, `ossec-logs/` and `suricata-logs/` never changed layout: always
`<prefix>/<server>/<yyyy-MM>/`.

## A server appears under two or three names

Three naming generations, and **they overlap rather than succeed each other**:

| generation | example | when |
|---|---|---|
| bare | `prodweb01` | 2018-08 onward |
| `a` suffix | `prodweb01a` | 2018-10 onward — **concurrent with the bare name for years**, not after it |
| `-arm` suffix | `prodweb01-arm` | 2026-08 onward, the amd64 → arm64 fleet migration |

So `prodweb01`'s weblogs run 2016-10 → 2026-09 across **four** prefixes:

```
weblogs/prodweb01/           2016-10 .. 2023-05   10,009 objects
weblogs/prod/prodweb01/      2023-04 .. 2025-01    2,875
weblogs/prod/prodweb01a/     2025-01 .. 2026-08    2,153
weblogs/prod/prodweb01-arm/  2026-08 .. 2026-09       44
```

Other chains worth knowing, all from `syslogs/`:

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

## Database backup series in `backups/mysql/`

The segment after `backups/mysql/` is a **series name**, usually `<cluster>-<region>`, and it has
changed as clusters moved:

| series | span | note |
|---|---|---|
| `bondlink-us-west-2` | 2018-12 .. 2024-02 | the original |
| `bondlink-us-east-1` | 2019-12 .. present | current prod OLTP |
| `bondlink-us-east-2` | 2024-02 .. 2026-03 | Ohio era |
| `analytics-us-east-1` | 2024-09 .. present | |
| `prodmonitor-us-east-1` | 2024-10 .. 2025-02 | |
| `wordpress-us-east-1` | 2022-11 .. 2023-02 | |
| `binlogs/<host>/` | | per-host, uses the host naming above |

**Staging has two spellings for the same thing** — `bondlink-staging-us-east-1` (2026-05..06) and
`staging-bondlink-us-east-1` (2026-09). Match both.

## Prefixes that exist because of a bug

Do not treat these as real series. They are what an unset or malformed variable produced:

| prefix | cause |
|---|---|
| `backups/mysql/None-us-east-1` | a null cluster name reached the path |
| `backups/mysql/bondlink--us-east-1` | an empty segment between the hyphens |
| `backups/mysql/bondlink-test` | a test run left in place |
| `syslogs/prodweb0420` | a mistyped hostname |
| `weblogs/prodjobsold` | a manual rename |
| `suricata-logs//` | **`$HOSTNAME` was empty** — see below |

`suricata-logs//` has an empty host segment because the backup ran `$HOSTNAME` in a shell that does
not set it (zsh, which `ssh.Command` invokes). Every host collided on one key per date, so the
prefix holds one surviving capture per day and the rest as noncurrent versions. Fixed in
kestra-automation#11 (OPS-123); the history stays collapsed.

## Before you conclude anything is missing

```bash
# Every prefix mentioning a host, across both weblogs layouts and all naming eras.
aws s3 ls s3://bondlink-data-ohio/weblogs/ --recursive | grep prodweb01 | head
aws s3api list-objects-v2 --bucket bondlink-data-ohio --region us-east-2 \
  --prefix weblogs/ --query 'Contents[?contains(Key, `prodweb01`)].Key' --output text
```

Match the **bare stem** (`prodweb01`), never the full hostname — `prodweb01` finds `prodweb01a` and
`prodweb01-arm` too, while `prodweb01a` finds neither the bare era nor the arm one.

Two more traps when reading these buckets:

- **`bondlink-data-ohio` is entirely `GLACIER`.** Objects are listed but not readable without a
  restore, and a `CopyObject` against one fails `InvalidObjectState`. The console renders them
  differently from Standard objects, which can read as an empty prefix.
- **`CopyObject` caps at 5 GiB.** `aws s3 cp` falls back to multipart and has no such limit; S3
  Batch Operations' `S3PutObjectCopy` does not and fails `InvalidRequest` above the cap.
