# pg-restore-wrapper

`pg_restore_wrapper.sh` is a Bash wrapper around PostgreSQL `pg_restore` (and `psql` for plain `.sql` dumps). It is the restore side of [pg-dump-wrapper](https://github.com/manideepgrandhi/pg-dump-wrapper) and follows the same rules: safe defaults, validation, one log, a summary table, documented exit codes and e-mail/webhook alerts.

```
pg_restore_wrapper.sh --from FILE -d DB [options] [-- extra pg_restore args]
pg_restore_wrapper.sh --from DIR (--map FILE=DB ... | --map-file F) [options]
pg_restore_wrapper.sh --from FILE|DIR ... --servers FILE [options]
```

Version 1.0.0. Needs Bash 4.4 or newer and the PostgreSQL client tools (`pg_restore`, `psql`, `pg_isready`). Safe for Aurora/RDS: it never runs superuser-only commands.

📘 Recipes for every scenario: [EXAMPLES.md](EXAMPLES.md) · 💡 Why not plain pg_restore: [WHY_THIS_WRAPPER.md](WHY_THIS_WRAPPER.md) · 🆕 [WHATS_NEW.md](WHATS_NEW.md) · [CHANGELOG.md](CHANGELOG.md) · [Sample config](pg_restore_wrapper.conf.example)

Settings are applied in this order (later ones win): **built-in defaults → `--config` file → command line**.

## What a run does

1. **Finds the dumps.** `--from` is a dump file, a directory-format dump, or a folder of dumps (scanned one level deep). If a folder has several dates of the same dump (`salesdb_20261117_010002.dump`, `salesdb_20261124_010015.dump`), the **newest** is used and the older ones are logged as skipped. `--include` can pin an older one.
2. **Maps files to databases, with no guessing.** A single file needs `-d DB`. A folder needs `--map 'salesdb_*=salesdb'` (repeatable, globs, first match wins) or `--map-file`. A selected file with no mapping stops the run with exit 2 before anything changes.
3. **Checks the checksums.** It verifies `<dump>.sha256` (written by `pg_dump_wrapper.sh --checksum`) when present. A mismatch is `FAIL(4)` for that file. A missing `.sha256` file only gives a warning.
4. **Checks each target.** It runs `pg_isready` and a test query. It decides whether each database exists (`--create` creates missing ones) and lists every table in the dump that **already exists** in the target.
5. **Protects existing tables.** If any exist, see [Existing tables](#existing-tables).
6. **Prints a RESTORE SUMMARY** (target, files → databases, options, checksums, backup plan). The summary is always written to the log.
7. **Asks for approval.** Type the exact target host name, or `RESTORE N` with `--servers` (N = number of servers that will be restored). `--yes` skips the prompt. Without `--yes`, the run needs a terminal and refuses (exit 2) when there isn't one.
8. **Takes the backups** (if planned). Any backup failure means **no restore starts** anywhere (exit 5).
9. **Restores** each file. A failure is `FAIL(3)`, and the other files still run unless `--stop-on-error`.
10. **Prints the rollback commands** and saves them to `OUTPUT_DIR/rollback_<date>.sh`, then the summary table, then sends alerts.

## Existing tables

These are tables in the dump that already exist in the target database (from `pg_restore --list` with your `-n`/`-t` filters, compared with the target's tables).

| How you run it | What happens |
|---|---|
| `--backup-first` or `--backup-first=dump` | After approval, `pg_dump_wrapper.sh` dumps just those tables (`-F custom --checksum -t ...`, one file per database) into `OUTPUT_DIR/pre_restore_backups/<host>_<port>/`. Rollback is a ready-made `pg_restore_wrapper.sh ... --clean --if-exists --force` command. |
| `--backup-first=psql` | Each table is copied in the same database to `<backup-schema>.<table>_bkp_<YYYYMMDD_HHMM>` with `CREATE TABLE ... (LIKE ... INCLUDING ALL)` + `INSERT ... (columns) OVERRIDING SYSTEM VALUE SELECT columns` (generated columns are left out and recomputed). If the name is taken, `_2`, `_3`, ... is added. The schema defaults to `public` (`--backup-schema`) and is created if missing. Rollback is `TRUNCATE` + `INSERT ... SELECT` from the copy. |
| `--force` | No backup. The summary says `NONE - --force`. |
| none of these, on a terminal | A WARNING lists the tables and asks `Back them up first? [dump / psql / skip / cancel]`. `dump`/`psql` take the backup right away, then continue to the summary and approval. `skip` needs you to type `OVERWRITE N` (N = number of tables). `cancel` or anything else stops with exit 2. |
| none of these, with `--yes` or no terminal (cron) | Refuses with exit 2, prints the `pg_dump_wrapper.sh` command you could run, and changes nothing. |

The wrapper does not count rows or compare sizes. Choose the method yourself: `psql` copies are quick for small tables and need space in the same database, while `dump` suits big tables.

**If tables exist and `--clean` is not set**, the run **refuses with exit 2** and nothing is restored (the backup prompt is not shown either). Use `--clean --if-exists` for a full replace, or `--data-only` to reload data only (the existing-table backup rules still apply).

## Options

### Connection
| Option | Purpose |
|---|---|
| `-h, --host HOST` | Server host. Default `$PGHOST`, otherwise `localhost`. |
| `-p, --port PORT` | Default `$PGPORT`, otherwise `5432`. |
| `-U, --user USER` | Default `$PGUSER`, otherwise `$USER`. |
| `-W, --password` | Asks once at the start (hidden) and keeps it in memory for this run only. Needs a terminal. Not allowed with `--servers`. |
| `--pgpassfile FILE` | Use this `.pgpass` file. **Passwords are never accepted on the command line or in the config file.** |
| `--maintenance-db DB` | Database used to list and create databases. Default `postgres`. |

### Many servers (`--servers FILE`)
Each line is `host,port,user,databases`. `databases` is `all` or a comma list of **target** databases to restore on that server. An empty `user` means `-U`. Blank lines, `#` comments, spaces and CRLF line endings are fine. Every selected dump is restored to each server, one server after another. The run has one summary, one log and one alert.
- `-h`, `-p` and `-W` are errors with `--servers`. Passwords come from the pgpass file (one line per `host:port`).
- A server that is down is a `FAIL(2) precheck` row, and the others still run. Approval is `RESTORE N`, where N counts only the reachable servers.
- All backups (on every server) run before any restore. One backup failure means no restore anywhere.

### Source and mapping
| Option | Purpose |
|---|---|
| `--from FILE\|DIR` | Dump file (`.dump`, `.tar`, `.sql`, `.sql.gz`, or anything `pg_restore` recognizes), a directory-format dump, or a folder of dumps. `.sha256` files and logs are ignored. `.sql.zst/.lz4/.bz2/.xz` files are skipped with a warning. |
| `-d, --dbname DB` | Target database for a single file. |
| `--map FILE=DB` | Folder: restore files matching `FILE` (name or glob) into `DB`. Repeatable or comma list. |
| `--map-file F` | One `FILE=DB` per line (`#` comments allowed). |
| `--include / --exclude PATTERN` | Glob filters on file names (repeatable). |
| `--stop-on-error` | Stop at the first failed restore and mark the rest `SKIPPED`. |

### Restore options
| Option | Purpose |
|---|---|
| `-j, --jobs N` | Parallel restore (custom/directory dumps; ignored with a warning for tar). |
| `-c, --clean` / `--if-exists` | Drop objects before recreating them / use `DROP ... IF EXISTS`. |
| `-C, --create` | Create the target database **only if it does not exist** (plain `CREATE DATABASE` from the maintenance db, after `SET ROLE` when `--role` is given). Without it, a missing database is `FAIL(2)`. |
| `-s, --schema-only` / `-a, --data-only` | Definitions only / data only. |
| `-n, --schema` / `-t, --table` | Restore only these schemas/tables (repeatable). For `-n`, the wrapper runs `CREATE SCHEMA IF NOT EXISTS` for each schema actually present in the dump (shown in the RESTORE SUMMARY and in `--dry-run`), so the schema does not have to exist already. `pg_restore -n` itself still does not emit `CREATE SCHEMA`. |
| `-O, --no-owner` | Skip ownership commands. **This is the default**, because on Aurora/RDS the master user is not a superuser and cannot become the dump's owner roles. |
| `--keep-owner` | Restore the dump's ownership commands (opt out of the default). If that fails with `must be able to SET ROLE`, the wrapper prints a hint to drop `--keep-owner` or use `--role`. Config: `keep_owner=yes` or `no_owner=no`. |
| `-x, --no-privileges` | Skip GRANT/REVOKE. |
| `--role ROLE` | `SET ROLE` before restoring (also for psql backups and `CREATE DATABASE`). |
| `-e, --exit-on-error` | Stop pg_restore at its first error. By default pg_restore continues, and the file is still `FAIL(3)` if any error happened. |
| `--no-checksum` | Do not verify `.sha256` files. |
| `-- ARGS` | Passed to pg_restore (or psql for plain dumps) unchanged. |

**Plain `.sql` / `.sql.gz`** dumps are restored with `psql -v ON_ERROR_STOP=1` (`gzip -dc | psql` for `.gz`). With `-O`, the wrapper drops `ALTER ... OWNER TO ...;` lines on the fly, and with `-x` it drops `GRANT`/`REVOKE` lines. `-j`, `-c`, `-n`, `-t`, `-s`, `-a` do not apply to plain dumps. Make the dump with the options you need instead.

### Existing tables, approval
| Option | Purpose |
|---|---|
| `--backup-first[=dump\|psql]` | See [Existing tables](#existing-tables). Config: `backup_first=yes\|dump\|psql`, `backup_method=dump\|psql`. |
| `--backup-schema NAME` | Schema for psql copies. Default `public`. |
| `--backup-dir DIR` | Folder for dump backups. Default `OUTPUT_DIR/pre_restore_backups`. |
| `--pg-dump-wrapper FILE` | Path to `pg_dump_wrapper.sh`. Default: next to this script, then `PATH`. |
| `--force` | Overwrite without a backup. Cannot be combined with `--backup-first`. |
| `-y, --yes` | Skip the typed approval. The summary is still logged. |

### Files, alerts, behaviour
| Option | Purpose |
|---|---|
| `-o, --output-dir DIR` | Log, rollback file and dump backups. Default `.` |
| `-l, --log-file FILE` | Default `OUTPUT_DIR/pg_restore_wrapper.log`. |
| `--min-free-mb N` | Warn if free space in `OUTPUT_DIR` is below N MB. Default 1024. |
| `--alert-email ADDR` | Mail the report (`mail`/`mailx`/`sendmail`). Repeatable. |
| `--alert-webhook URL` | POST the report with curl. `--alert-webhook-format slack\|json`. Tokens are never logged. |
| `--alert-on failure\|always`, `--alert-from ADDR`, `--alert-test` | When to alert, the From address, and a test alert. Alerts never change the exit code. A run cancelled at a prompt sends no alert. |
| `--config FILE` | `key=value` settings, parsed and never executed. Unknown keys are rejected. |
| `--dry-run` | Shows the plan, the summary and the exact commands, and changes nothing. It still connects to read databases and tables. |
| `--skip-precheck` | Skip `pg_isready` and the free-space check. |
| `--pg-bin DIR`, `-v`, `--help`, `--version` | |

## Output

```
2026-11-25 04:50:14 [INFO] Summary:
2026-11-25 04:50:14 [INFO]   DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
2026-11-25 04:50:14 [INFO]   hrdb_new                 OK        -          4.0K     0m01s    /backups/postgres/db1.example.internal_5432/hrdb_20261125_045011.dump
2026-11-25 04:50:14 [INFO]   salesdb                  FAIL(3)   restore    8.0K     0m00s    /backups/postgres/db1.example.internal_5432/salesdb_20261125_045011.dump
2026-11-25 04:50:14 [ERROR] Run finished with exit code 3 (stage: restore (salesdb))
```

With `--servers`, the rows are `host:port/db`, in servers-file order. A full set of real runs is in [EXAMPLES.md](EXAMPLES.md).

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Everything restored |
| 1 | Usage / configuration error |
| 2 | Pre-check failed, refused (no approval, no terminal, unmapped file, existing tables without a backup) or cancelled |
| 3 | A restore failed |
| 4 | Checksum mismatch |
| 5 | A pre-restore backup failed (nothing was restored) |
| 130 | Interrupted (Ctrl-C / TERM) |

Runs with several files or servers exit with the highest code of any row.

## Known limits

- `--backup-first=psql` copies and rollbacks list the columns explicitly and leave out generated columns (PostgreSQL recomputes them), so tables with `GENERATED ALWAYS AS (...) STORED` columns work.
- The psql rollback will not run a bare `TRUNCATE` on a table that other tables (not in the backup) still reference. It warns, recommends the dump method, and comments a `TRUNCATE ... CASCADE` alternative that would also empty those referencing tables.
- Restores run one file after another. `-j` gives parallelism inside one restore.
- Tested on Linux with PostgreSQL 17 (see `tests/`). Windows Git Bash paths are handled the same way as in pg_dump_wrapper but have not been tested here.

## Tests

`tests/test_pg_restore_wrapper.sh` starts two throwaway PostgreSQL clusters, makes dumps with the real `pg_dump_wrapper.sh`, and runs the wrapper as a **non-superuser role with CREATEDB**, like the Aurora master user.

```
PRW_SERVER_BIN=/usr/lib/postgresql/17/bin PRW_DUMP_WRAPPER=/path/to/pg_dump_wrapper.sh bash tests/test_pg_restore_wrapper.sh
```

It needs util-linux `script` and `setsid` (to type answers into the prompts and to simulate cron), and Python 3 for the webhook test.
