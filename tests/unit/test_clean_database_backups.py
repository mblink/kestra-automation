"""Execution tests for the backup pruner.

Every case here is a bug that reached a branch, not a hypothetical. The script deletes production
database backups, and the existing static suite cannot see its arithmetic: a wrong band boundary
looks exactly like a right one until a restore fails.

See shell_harness.py for why these run the script for real.
"""
import subprocess

import pytest

from tests.unit.shell_harness import PRUNER, banded, run_pruner

DAY = "2026-09-08_07-38-35"


def keys(*names):
    return [f"{n}/" for n in names]


def test_dry_run_deletes_nothing(tmp_path):
    """--live is the only thing that may delete. The flow passes it; a human checking a prefix
    should not have to remember not to."""
    rc, out, deletions = banded(tmp_path, keys("2019-01-02_00-00-00", DAY))
    assert rc == 0, out
    assert deletions == [], f"dry run issued deletes: {deletions}"


def test_failed_listing_aborts_instead_of_deleting_everything(tmp_path):
    """An `aws s3 ls` that errors used to reach the loop as an empty result, and an empty result
    means every retained date is absent -- i.e. nothing to keep."""
    rc, out, deletions = banded(tmp_path, keys(DAY), "--live", ls_fails=True)
    assert rc != 0
    assert deletions == []
    assert "listing" in out.lower()


def test_unparseable_keys_are_never_deleted(tmp_path):
    """A key whose shape the recogniser does not know is not a backup this job owns."""
    rc, out, deletions = banded(
        tmp_path, keys("final-db02-snapshot", "mysql.aB12cD", "2019-01-02_00-00-00"), "--live"
    )
    assert rc == 0, out
    assert not any("final-db02-snapshot" in d or "mysql.aB12cD" in d for d in deletions), deletions


def test_missing_flag_value_exits_rather_than_hanging(tmp_path):
    """A flag as the last token left `shift 2` failing under a loop that re-read the same token."""
    proc = subprocess.run(
        ["bash", str(PRUNER), "--bucket"], capture_output=True, text=True, timeout=20, check=False
    )
    assert proc.returncode == 2, proc.stdout + proc.stderr


@pytest.mark.parametrize("locale", ["C.UTF-8", "de_DE.UTF-8", "fr_FR.UTF-8"])
def test_sunday_retention_does_not_depend_on_locale(tmp_path, locale):
    """The weekly tier kept `date +%A == "Sunday"`, which is the day name in the runner's locale.
    Under a non-English LC_TIME nothing matched and the whole weekly band was deletable."""
    sunday, monday = "2024-11-03_00-00-00", "2024-11-04_00-00-00"
    rc, out, deletions = banded(tmp_path, keys(sunday, monday), "--live", env={"LC_ALL": locale})
    assert rc == 0, out
    assert not any(sunday in d for d in deletions), f"{locale}: deleted a Sunday: {deletions}"


def test_database_name_with_underscore_is_recognised(tmp_path):
    """The dated-dump recogniser required [A-Za-z0-9] after the stamp, so a schema name with an
    underscore -- which MariaDB allows and this fleet has -- was silently never pruned."""
    old = "20190102030405_test_db.sql.zst"
    rc, out, deletions = run_pruner(
        tmp_path, [old],
        "--bucket", "bondlink-data-east", "--prefix", "backups/mysql/mariadb-dump",
        "--retain", "banded", "--mode", "marker", "--live",
    )
    assert rc == 0, out
    assert "1 unrecognised" not in out and "unrecognised: 1" not in out, out
    assert any(old in d for d in deletions), f"an underscore name was not pruned: {out}"


def test_bucket_wide_lifecycle_rule_satisfies_the_precondition(tmp_path):
    """A rule with no Prefix covers every key. The check required a non-empty prefix and so
    refused marker mode against exactly the bucket-wide shape the archive is getting."""
    rc, out, _ = banded(
        tmp_path, keys(DAY),
        lifecycle={"Rules": [{
            "ID": "whole-bucket", "Status": "Enabled", "Filter": {},
            "NoncurrentVersionExpiration": {"NoncurrentDays": 30},
            "Expiration": {"ExpiredObjectDeleteMarker": True},
        }]},
    )
    assert rc == 0, out
    assert "Refusing --mode marker" not in out, out


def test_marker_mode_refused_when_the_rule_carries_other_and_qualifiers(tmp_path):
    """Prefix + Tag reaps only the tagged subset, so it does not license marker mode for the
    prefix as a whole."""
    rc, out, deletions = banded(
        tmp_path, keys(DAY), "--live",
        lifecycle={"Rules": [{
            "ID": "tagged", "Status": "Enabled",
            "Filter": {"And": {"Prefix": "backups/mysql", "Tags": [{"Key": "k", "Value": "v"}]}},
            "NoncurrentVersionExpiration": {"NoncurrentDays": 1},
            "Expiration": {"ExpiredObjectDeleteMarker": True},
        }]},
    )
    assert rc != 0
    assert deletions == []
    assert "Refusing --mode marker" in out, out


def test_marker_mode_refused_when_a_matching_rule_is_disabled(tmp_path):
    rc, out, deletions = banded(
        tmp_path, keys(DAY), "--live",
        lifecycle={"Rules": [{
            "ID": "off", "Status": "Disabled", "Filter": {"Prefix": "backups/mysql"},
            "NoncurrentVersionExpiration": {"NoncurrentDays": 1},
            "Expiration": {"ExpiredObjectDeleteMarker": True},
        }]},
    )
    assert rc != 0
    assert deletions == []
    assert "Refusing --mode marker" in out, out


def test_last_days_refuses_a_series_that_has_stopped(tmp_path):
    """A flat age rule has no floor; this one refuses rather than emptying a prefix whose producer
    died. The analytics job silently produced nothing on two days in August 2026."""
    stale = keys("2020-01-01_00-00-00", "2020-01-02_00-00-00", "2020-01-03_00-00-00",
                 "2020-01-04_00-00-00")
    __rc, out, deletions = run_pruner(
        tmp_path, stale,
        "--bucket", "bondlink-data-east", "--prefix", "backups/mysql/bondlink-us-east-1",
        "--retain", "last-days", "--keep-days", "3", "--max-stale-days", "3",
        "--mode", "marker", "--live",
    )
    assert deletions == [], f"deleted from a stale series: {deletions}"
    assert "stale" in out.lower(), out


def test_last_days_deletes_nothing_when_fewer_dates_exist_than_it_keeps(tmp_path):
    __rc, out, deletions = run_pruner(
        tmp_path, keys("2026-09-07_00-00-00", "2026-09-08_00-00-00"),
        "--bucket", "bondlink-data-east", "--prefix", "backups/mysql/bondlink-us-east-1",
        "--retain", "last-days", "--keep-days", "3", "--max-stale-days", "3650",
        "--mode", "marker", "--live",
    )
    assert deletions == [], out


# With today pinned to 2026-09-09 the script computes START_WEEKLY 2025-09-08 and END_WEEKLY
# 2024-09-08, which is a Sunday -- the exact date the weekly/monthly boundary used to lose.
PINNED_TODAY = {"FAKE_TODAY": "2026-09-09"}
END_WEEKLY_SUNDAY = "2024-09-08_00-00-00"


def test_the_date_on_the_weekly_far_edge_is_judged_by_the_weekly_rule(tmp_path):
    """START_MONTHLY is END_WEEKLY + 1 day, so a strict `> END_WEEKLY` left exactly one date in
    neither band's keep rule: it fell through to the monthly test and was deleted for not being
    the 1st. When that date is a Sunday the weekly tier is supposed to keep it, and roughly one
    day in seven it is."""
    rc, out, deletions = banded(
        tmp_path, keys(END_WEEKLY_SUNDAY), "--live", env=PINNED_TODAY
    )
    assert rc == 0, out
    assert not any(END_WEEKLY_SUNDAY in d for d in deletions), (
        f"deleted the Sunday on the weekly boundary: {deletions}\n{out}"
    )


def test_a_non_sunday_on_the_weekly_far_edge_is_still_deletable(tmp_path):
    """The complement of the case above -- closing the gap must not turn the boundary into a
    blanket keep, or the weekly tier stops reclaiming anything at its edge."""
    rc, out, deletions = banded(
        tmp_path, keys("2024-09-09_00-00-00"), "--live", env=PINNED_TODAY
    )
    assert rc == 0, out
    assert any("2024-09-09" in d for d in deletions), f"kept a Monday inside the weekly band: {out}"


def test_a_compressed_backup_is_recognised_and_pruned_like_its_directory(tmp_path):
    """ship_phase writes <stamp>.7z where it used to write <stamp>/. The stamp recogniser is
    anchored on the stamp alone, so both shapes must land in the same band -- a .7z the pruner
    called unrecognised would accumulate forever under a prefix that carries no expiry rule."""
    old = "2019-01-02_00-00-00"
    rc, out, deletions = run_pruner(
        tmp_path, [f"{old}.7z", f"{DAY}.7z"],
        "--bucket", "bondlink-data-east", "--prefix", "backups/mysql/bondlink-us-east-1",
        "--retain", "banded", "--mode", "marker", "--live",
    )
    assert rc == 0, out
    assert any(f"{old}.7z" in d for d in deletions), f"an archive was not pruned: {out}"
    assert not any(f"{DAY}.7z" in d for d in deletions), f"pruned a recent archive: {deletions}"


def test_an_archive_is_deleted_as_one_object_not_recursively(tmp_path):
    """--recursive is chosen by a trailing slash. Passing it for an object key makes `aws s3 rm`
    treat the key as a prefix, which matches nothing and silently deletes neither."""
    old = "2019-01-02_00-00-00"
    rc, out, deletions = run_pruner(
        tmp_path, [f"{old}.7z", f"{old}/"],
        "--bucket", "bondlink-data-east", "--prefix", "backups/mysql/bondlink-us-east-1",
        "--retain", "banded", "--mode", "marker", "--live",
    )
    assert rc == 0, out
    archive_deletes = [d for d in deletions if ".7z" in d]
    assert archive_deletes, f"the archive was not deleted at all: {out}"
    assert not any("--recursive" in d for d in archive_deletes), archive_deletes


def test_a_directory_backup_is_still_deleted_recursively(tmp_path):
    """Guard on the legacy shape: dropping --recursive there leaves every object in place while
    the command still reports success."""
    rc, out, deletions = run_pruner(
        tmp_path, ["2019-01-02_00-00-00/"],
        "--bucket", "bondlink-data-east", "--prefix", "backups/mysql/bondlink-us-east-1",
        "--retain", "banded", "--mode", "marker", "--live",
    )
    assert rc == 0, out
    assert any("--recursive" in d for d in deletions), f"no recursive delete issued: {deletions}"
