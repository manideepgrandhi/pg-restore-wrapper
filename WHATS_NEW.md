# What's new

## pg_restore_wrapper.sh 1.0.0 (2026-11-25)

The restore side of [pg_dump_wrapper.sh](https://github.com/manideepgrandhi/pg-dump-wrapper). It takes what `pg_dump_wrapper.sh` writes and puts it back safely.

**In short**
- **Point it at a dump or a whole backup folder.** It picks the newest dump of each database, checks the `.sha256`, and restores into the database you mapped. Nothing is guessed from file names.
- **`--no-owner` is the default**, so Aurora/RDS restores work without a special flag. Use `--keep-owner` only when you really want the dump's owners.
- **It never overwrites a table silently.** Tables that already exist are listed. You back them up first (with `pg_dump_wrapper.sh`, or a quick `_bkp_` copy with psql), confirm `OVERWRITE N`, or cancel. Cron runs refuse unless you said `--backup-first` or `--force`. If `--clean` is missing (and you did not pass `--data-only`), the run refuses with exit 2.
- **`-n SCHEMA` creates the schema first** (`CREATE SCHEMA IF NOT EXISTS`), so a filtered restore works on an empty database.
- **You see what will happen before it happens.** A RESTORE SUMMARY, then you type the host name (or `RESTORE N` for many servers). `--dry-run` shows the exact commands.
- **Undo is ready.** Rollback commands are printed and saved as a script at the end of every run that took a backup.
- **Many servers in one run** with `--servers`, using the same file format as pg_dump_wrapper.
- **Works on Aurora/RDS** as the non-superuser master user, with a clear hint if `--keep-owner` fails on `SET ROLE`.

Try it safely first:
```bash
pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432 --map 'salesdb_*=salesdb' \
  -h db2.example.internal -U dba_admin --clean --if-exists --no-owner --dry-run
```

Details: [README.md](README.md) · Recipes and real output: [EXAMPLES.md](EXAMPLES.md) · Full list: [CHANGELOG.md](CHANGELOG.md)
