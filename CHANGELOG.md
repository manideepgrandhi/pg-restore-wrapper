# Changelog

## pg_restore_wrapper.sh

### 1.0.0 (2026-11-25)

First release.

**Added**
- Restore a dump file, a directory-format dump, or a folder of dumps (`--from`). Supports custom, directory and tar via `pg_restore`, and plain `.sql` / `.sql.gz` via `psql -v ON_ERROR_STOP=1`.
- No file-name guessing: a single file needs `-d DB`; a folder needs `--map FILE=DB` (globs, first match wins) or `--map-file`. An unmapped selected file stops the run (exit 2). `--include` / `--exclude` globs.
- Newest dump wins when a folder holds several dates of the same dump. Older ones are logged as skipped, and `--include` can pin one.
- `.sha256` verification (from `pg_dump_wrapper.sh --checksum`): a mismatch is `FAIL(4)`, a missing file is a warning, and `--no-checksum` turns it off.
- Existing-table protection. Tables in the dump that already exist in the target are listed, then:
  - `--backup-first` / `--backup-first=dump` backs them up with `pg_dump_wrapper.sh` (one file per database).
  - `--backup-first=psql` copies them to `<backup-schema>.<table>_bkp_<YYYYMMDD_HHMM>`, adding `_2`, `_3` on a name collision. `--backup-schema` defaults to `public`.
  - `--force` overwrites without a backup.
  - With none of these, on a terminal, you get the prompt `dump / psql / skip / cancel`. `skip` needs `OVERWRITE N`.
  - `--yes` or no terminal refuses with exit 2.
  - Any backup failure means no restore starts (exit 5).
- RESTORE SUMMARY before every restore, always logged. Typed approval: the target host name, or `RESTORE N` with `--servers`. `--yes` skips the prompt. With no terminal and no `--yes`, the run refuses.
- Rollback commands printed at the end and saved as `OUTPUT_DIR/rollback_<date>.sh`.
- `--servers FILE` (`host,port,user,databases`): one run, one summary, one log, one alert. A down server is a `FAIL(2)` row. All backups run before any restore.
- `--create` creates the target database only when it does not exist. `-j`, `--clean`, `--if-exists`, `-s`, `-a`, `-n`, `-t`, `-O`, `-x`, `--role`, `-e`, and `--` for extra arguments.
- Aurora/RDS friendly: no superuser-only commands. A `must be able to SET ROLE` failure gets a `--no-owner` hint. For plain dumps, `-O` / `-x` drop `OWNER TO` / `GRANT` / `REVOKE` lines.
- Warning when existing tables would be restored without `--clean`.
- psql backup copies and rollbacks list columns explicitly, so generated columns work.
- Same conventions as pg_dump_wrapper: config file (`key=value`, no passwords), `.pgpass` / `--pgpassfile` / `-W`, log format, summary table, e-mail and Slack/JSON webhook alerts, `--alert-test`, `--dry-run`, `--pg-bin`.
- Exit codes: 0 ok, 1 usage, 2 pre-check/refused/cancelled, 3 restore, 4 checksum, 5 backup, 130 interrupted.
- Test suite against real PostgreSQL 17, run as a non-superuser role (`tests/test_pg_restore_wrapper.sh`).
