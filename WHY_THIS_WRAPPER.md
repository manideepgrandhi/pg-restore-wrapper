# Why use pg_restore_wrapper.sh instead of pg_restore?

`pg_restore` is a good tool, but it does exactly what you type, on whatever server your environment points at, with no second chance. Most restore incidents are not pg_restore bugs. They are restores into the wrong server or database, over tables someone still needed, with no way back.

## What it adds

| | plain `pg_restore` | `pg_restore_wrapper.sh` |
|---|---|---|
| Shows what will happen first | no | RESTORE SUMMARY: target, files → databases, options, checksums, backup plan |
| Stops a restore into the wrong server | no | type the exact host name (or `RESTORE N` for many servers); cron needs `--yes` |
| Existing tables | overwritten (with `--clean`) or errors | listed; backup first (pg_dump_wrapper or psql copy), `OVERWRITE N`, or cancel; refuses without `--clean` (unless `--data-only`); cron also needs `--backup-first`/`--force` |
| Undo | your problem | rollback commands printed and saved as a script |
| Folder of dumps | one command per file | one run; newest dump per database; explicit `--map` |
| Checksums | no | verifies `.sha256` from pg_dump_wrapper |
| Missing database | error (or `-C`, which needs the right connection and owner) | `--create` makes it only when it doesn't exist |
| Plain `.sql` / `.sql.gz` | a different tool (`psql`) and flags | the same command; `-O`/`-x` work for plain dumps too |
| Many servers | a loop you write | `--servers`, one summary and one alert |
| Result | read the output | summary table, one log, exit codes by stage, e-mail/webhook alerts |
| Aurora/RDS | fails on `OWNER TO` with no explanation | `--no-owner` is the default; a hint if `--keep-owner` fails; no superuser-only commands |

## Before and after

Before: restore last night's dump into UAT.
```bash
export PGHOST=uat.example.internal          # hopefully not prod
pg_dump -h uat.example.internal -d salesdb -t sales.orders -Fc -f /tmp/orders_before.dump   # if you remember
pg_restore -d salesdb --clean --if-exists --no-owner -j 4 /backups/salesdb_20261124_010015.dump
echo $?                                     # 1, with 40 lines of errors to read
```

After:
```bash
pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432 --map 'salesdb_*=salesdb' \
  -h uat.example.internal -U dba_admin --clean --if-exists --no-owner -j 4 --backup-first
```
You get the file it picked and why, the checksum result, the tables that exist, a summary, and the host-name prompt. Then a pg_dump_wrapper backup of exactly those tables, the restore, a summary row with `OK` or `FAIL(3) restore`, and a rollback script.

## When plain pg_restore is enough

- A throwaway local database you are about to drop anyway.
- Restoring into a brand-new empty database by hand, once, while watching it.
- Special options the wrapper does not cover. You can still pass them after `--`, or use pg_restore directly.

## What it does not do

- It does not count rows or compare sizes after the restore. Use your own checks (or `psql_wrapper.sh query`) for that.
- It does not decide the backup method for you. `psql` copies are quick for small tables, and `dump` suits big ones.
- It does not guess which database a file belongs to.
