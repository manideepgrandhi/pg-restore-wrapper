# pg_restore_wrapper.sh: usage examples (v1.0.0)

These are copy-paste recipes for `pg_restore_wrapper.sh`. Each example has
**when to use it**, **the command**, and **sample output** from a real run
(PostgreSQL 17, non-superuser login). Hosts, users, paths and alert targets
below are placeholders (`db1.example.internal`, `dba_admin`, `dba@example.com`,
`hooks.slack.com/services/XXX`). Replace them with your own values.

For the full option reference, see [README.md](README.md).

Put the password in `~/.pgpass` or pass `--pgpassfile`. Every restore asks
for approval (type the target host name, or `RESTORE N` with `--servers`)
unless you pass `--yes`. `--no-owner` is the default (needed on Aurora/RDS);
use `--keep-owner` to opt out. `--from` is a file or a folder; nothing is
guessed from file names.

## Contents
1. [Restore a single dump file](#1-restore-a-single-dump-file)
2. [Dry run](#2-dry-run)
3. [Restore a backup folder with a map file](#3-restore-a-backup-folder-with-a-map-file)
4. [Back up first with dump (default)](#4-back-up-first-with-dump-default)
5. [Back up first with psql](#5-back-up-first-with-psql)
6. [The existing-table prompt](#6-the-existing-table-prompt)
7. [One schema or table (or schema-only / data-only)](#7-one-schema-or-table-or-schema-only--data-only)
8. [Many servers with `--servers`](#8-many-servers-with---servers)
9. [Test e-mail and webhook alerts](#9-test-e-mail-and-webhook-alerts)
10. [Backup failed (exit 5)](#10-backup-failed-exit-5)
11. [Exit codes](#11-exit-codes)

---

## 1. Restore a single dump file
**When:** you have one dump and want it applied to one database. `--create` makes the database if it does not exist yet.
```bash
./pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump \
  -d salesdb -h db2.example.internal -U dba_admin --create --yes -o /backups/restore-work
```
**Sample output:**
```
2026-11-25 10:12:10 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 10:12:10 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 10:12:10 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 10:12:10 [INFO] File map (1):
2026-11-25 10:12:10 [INFO]   salesdb_20261125_101209.dump -> salesdb  (8.0K, custom)
2026-11-25 10:12:10 [INFO] Checksum OK: salesdb_20261125_101209.dump
2026-11-25 10:12:10 [INFO] Connected: server_version_num=170012

RESTORE SUMMARY
  Target     : db2.example.internal:5432  user=dba_admin
  Source     : /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump  (1 file(s), 8.0K)
  Files      : salesdb_20261125_101209.dump -> salesdb  (new, will be created)
  Options    : --create --no-owner
  Checksums  : 1 OK
  Backup     : none needed (no existing tables will be overwritten)

2026-11-25 10:12:10 [INFO] Approval skipped (--yes)
2026-11-25 10:12:10 [INFO] [salesdb] Creating database salesdb (--create; it does not exist)
2026-11-25 10:12:10 [INFO] [salesdb] Starting restore (custom) <- /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:10 [INFO] [salesdb] Command: pg_restore -h db2.example.internal -p 5432 -U dba_admin -d salesdb --no-password --no-owner /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:10 [INFO] [salesdb] Restore finished in 0m00s
2026-11-25 10:12:10 [INFO] Summary:
2026-11-25 10:12:10 [INFO]   DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
2026-11-25 10:12:10 [INFO]   salesdb                  OK        -          8.0K     0m00s    /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:10 [INFO] Run finished OK in 0m00s
```

A directory-format dump works the same way: pass the `.dir` folder as `--from`.

---

## 2. Dry run
**When:** you want to see the plan, the file map and the exact commands without changing anything (no backup, no restore, no alert).
```bash
./pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432 \
  --map 'salesdb_*=salesdb' --map 'hrdb_*=hrdb' \
  -h db2.example.internal -U dba_admin --create --clean --if-exists -j 4 --dry-run \
  -o /backups/restore-work
```
**Sample output:**
```
2026-11-25 10:12:10 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 10:12:10 [INFO] DRY RUN - nothing will be created, backed up or restored
2026-11-25 10:12:10 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 10:12:10 [INFO] Source /backups/postgres/db1.example.internal_5432: 2 dump file(s) selected, 1 older file(s) skipped
2026-11-25 10:12:10 [INFO] Skipping older dump (a newer file of the same dump is selected): /backups/postgres/db1.example.internal_5432/salesdb_20261117_010002.dump
2026-11-25 10:12:10 [INFO] File map (2):
2026-11-25 10:12:10 [INFO]   hrdb_20261125_101209.dir     -> hrdb  (12K, directory)
2026-11-25 10:12:10 [INFO]   salesdb_20261125_101209.dump -> salesdb  (8.0K, custom)
2026-11-25 10:12:10 [INFO] Checksum OK: hrdb_20261125_101209.dir
2026-11-25 10:12:10 [INFO] Checksum OK: salesdb_20261125_101209.dump
2026-11-25 10:12:10 [INFO] Connected: server_version_num=170012
2026-11-25 10:12:11 [WARN] 3 existing table(s) would be overwritten by this restore:
2026-11-25 10:12:11 [WARN]   db2.example.internal:5432/salesdb: public.regions, sales.customers, sales.orders
2026-11-25 10:12:11 [INFO] DRY RUN - would ask: back them up first? [dump / psql / skip / cancel]

RESTORE SUMMARY
  Target     : db2.example.internal:5432  user=dba_admin
  Source     : /backups/postgres/db1.example.internal_5432  (2 file(s), 20K; 1 older file(s) skipped)
  Files      : hrdb_20261125_101209.dir     -> hrdb  (new, will be created)
               salesdb_20261125_101209.dump -> salesdb  (exists, 3 table(s) will be overwritten)
  Options    : --clean --if-exists --create -j 4 --no-owner
  Checksums  : 2 OK
  Backup     : 3 table(s) via pg_dump_wrapper.sh -> /backups/restore-work/pre_restore_backups/

2026-11-25 10:12:11 [INFO] DRY RUN - pre-restore backup (dump) would run:
bash /opt/pg-tools/pg_dump_wrapper.sh -h db2.example.internal -p 5432 -U dba_admin -d salesdb -F custom --checksum --table-sizes 0 --min-free-mb 1024 -o /backups/restore-work/pre_restore_backups/db2.example.internal_5432 --pgpassfile /home/dba/.pgpass -t \"public\".\"regions\" -t \"sales\".\"customers\" -t \"sales\".\"orders\"
2026-11-25 10:12:11 [INFO] DRY RUN - restore commands:
psql -X -w -q -v ON_ERROR_STOP=1 -h db2.example.internal -p 5432 -U dba_admin -d postgres -c CREATE\ DATABASE\ \"hrdb\"
pg_restore -h db2.example.internal -p 5432 -U dba_admin -d hrdb --no-password --jobs=4 --clean --if-exists --no-owner /backups/postgres/db1.example.internal_5432/hrdb_20261125_101209.dir
pg_restore -h db2.example.internal -p 5432 -U dba_admin -d salesdb --no-password --jobs=4 --clean --if-exists --no-owner /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:11 [INFO] DRY RUN - approval would be required: type db2.example.internal
```

---

## 3. Restore a backup folder with a map file
**When:** a dump-wrapper folder holds several databases and more than one date. Map each file (or glob) to a target database; the newest file of each dump is used, and older ones are skipped. `--exclude` drops a dump you do not want; `--include` can pin an older file.
```bash
# /etc/pg_restore/map.txt
# FILE=DB  (name or shell glob; first match wins)
salesdb_*=salesdb_uat
hrdb_*=hrdb_uat
```
```bash
./pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432 \
  --map-file /etc/pg_restore/map.txt --exclude 'hrdb_*' \
  -h db2.example.internal -U dba_admin --create --yes -o /backups/restore-work
```
**Sample output:**
```
2026-11-25 10:12:11 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 10:12:11 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 10:12:11 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 10:12:11 [INFO] Excluded by --exclude: hrdb_20261125_101209.dir
2026-11-25 10:12:11 [INFO] Source /backups/postgres/db1.example.internal_5432: 1 dump file(s) selected, 1 older file(s) skipped
2026-11-25 10:12:11 [INFO] Skipping older dump (a newer file of the same dump is selected): /backups/postgres/db1.example.internal_5432/salesdb_20261117_010002.dump
2026-11-25 10:12:11 [INFO] File map (1):
2026-11-25 10:12:11 [INFO]   salesdb_20261125_101209.dump -> salesdb_uat  (8.0K, custom)
2026-11-25 10:12:11 [INFO] Checksum OK: salesdb_20261125_101209.dump
2026-11-25 10:12:11 [INFO] Connected: server_version_num=170012

RESTORE SUMMARY
  Target     : db2.example.internal:5432  user=dba_admin
  Source     : /backups/postgres/db1.example.internal_5432  (1 file(s), 8.0K; 1 older file(s) skipped)
  Files      : salesdb_20261125_101209.dump -> salesdb_uat  (new, will be created)
  Options    : --create --no-owner
  Checksums  : 1 OK
  Backup     : none needed (no existing tables will be overwritten)

2026-11-25 10:12:11 [INFO] Approval skipped (--yes)
2026-11-25 10:12:11 [INFO] [salesdb_uat] Creating database salesdb_uat (--create; it does not exist)
2026-11-25 10:12:11 [INFO] [salesdb_uat] Starting restore (custom) <- /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:11 [INFO] [salesdb_uat] Command: pg_restore -h db2.example.internal -p 5432 -U dba_admin -d salesdb_uat --no-password --no-owner /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:11 [INFO] [salesdb_uat] Restore finished in 0m00s
2026-11-25 10:12:11 [INFO] Summary:
2026-11-25 10:12:11 [INFO]   DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
2026-11-25 10:12:11 [INFO]   salesdb_uat              OK        -          8.0K     0m00s    /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:11 [INFO] Run finished OK in 0m00s
```

To restore an older dump instead of the newest, pin it with `--include`:
```bash
./pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432 \
  --include 'salesdb_20261117_*' --map 'salesdb_*=salesdb' \
  -h db2.example.internal -U dba_admin --create --yes -o /backups/restore-work
```

---

## 4. Back up first with dump (default)
**When:** the target already has tables and you want a `pg_dump` copy of them before the restore. `--backup-first` (or `--backup-first=dump`) runs `pg_dump_wrapper.sh`, then restores. Copies are kept for manual recovery; the wrapper does not roll anything back.
```bash
./pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump \
  -d salesdb -h db2.example.internal -U dba_admin --clean --if-exists --backup-first --yes \
  -o /backups/restore-work
```
**Sample output:**
```
2026-11-25 10:12:11 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 10:12:11 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 10:12:11 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 10:12:11 [INFO] File map (1):
2026-11-25 10:12:11 [INFO]   salesdb_20261125_101209.dump -> salesdb  (8.0K, custom)
2026-11-25 10:12:11 [INFO] Checksum OK: salesdb_20261125_101209.dump
2026-11-25 10:12:11 [INFO] Connected: server_version_num=170012

RESTORE SUMMARY
  Target     : db2.example.internal:5432  user=dba_admin
  Source     : /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump  (1 file(s), 8.0K)
  Files      : salesdb_20261125_101209.dump -> salesdb  (exists, 3 table(s) will be overwritten)
  Options    : --clean --if-exists --no-owner
  Checksums  : 1 OK
  Backup     : 3 table(s) via pg_dump_wrapper.sh -> /backups/restore-work/pre_restore_backups/

2026-11-25 10:12:11 [INFO] Approval skipped (--yes)
2026-11-25 10:12:11 [INFO] Starting pre-restore backups (dump): 3 table(s)
2026-11-25 10:12:11 [INFO] [salesdb] Backing up public.regions, sales.customers, sales.orders with pg_dump_wrapper.sh
2026-11-25 10:12:11 [INFO] [salesdb] Command: bash /opt/pg-tools/pg_dump_wrapper.sh -h db2.example.internal -p 5432 -U dba_admin -d salesdb -F custom --checksum --table-sizes 0 --min-free-mb 1024 -o /backups/restore-work/pre_restore_backups/db2.example.internal_5432 --pgpassfile /home/dba/.pgpass -t \"public\".\"regions\" -t \"sales\".\"customers\" -t \"sales\".\"orders\"
2026-11-25 10:12:12 [INFO] [salesdb] pg_dump_wrapper.sh OK: /backups/restore-work/pre_restore_backups/db2.example.internal_5432/salesdb_20261125_101211.dump (8.0K, 0m01s)
2026-11-25 10:12:12 [INFO] Pre-restore backups finished OK (dump)
2026-11-25 10:12:12 [INFO] [salesdb] Starting restore (custom) <- /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:12 [INFO] [salesdb] Command: pg_restore -h db2.example.internal -p 5432 -U dba_admin -d salesdb --no-password --clean --if-exists --no-owner /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:12 [INFO] [salesdb] Restore finished in 0m00s
2026-11-25 10:12:12 [INFO] Pre-restore backups saved:
  [dump] db2.example.internal:5432/salesdb  /backups/restore-work/pre_restore_backups/db2.example.internal_5432/salesdb_20261125_101211.dump
2026-11-25 10:12:12 [INFO] Summary:
2026-11-25 10:12:12 [INFO]   DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
2026-11-25 10:12:12 [INFO]   salesdb                  OK        -          8.0K     0m00s    /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:12 [INFO] Run finished OK in 0m01s
```

---

## 5. Back up first with psql
**When:** you want a quick in-database copy instead of a dump file. Each table is copied to `<backup-schema>.<table>_bkp_<YYYYMMDD_HHMM>` (`public` by default; `_2`, `_3` on a name collision).
```bash
./pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump \
  -d salesdb -h db2.example.internal -U dba_admin --clean --if-exists --backup-first=psql --yes \
  -o /backups/restore-work
```
**Sample output:**
```
2026-11-25 10:12:12 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 10:12:12 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 10:12:12 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 10:12:12 [INFO] File map (1):
2026-11-25 10:12:12 [INFO]   salesdb_20261125_101209.dump -> salesdb  (8.0K, custom)
2026-11-25 10:12:12 [INFO] Checksum OK: salesdb_20261125_101209.dump
2026-11-25 10:12:12 [INFO] Connected: server_version_num=170012

RESTORE SUMMARY
  Target     : db2.example.internal:5432  user=dba_admin
  Source     : /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump  (1 file(s), 8.0K)
  Files      : salesdb_20261125_101209.dump -> salesdb  (exists, 3 table(s) will be overwritten)
  Options    : --clean --if-exists --no-owner
  Checksums  : 1 OK
  Backup     : 3 table(s) psql copy -> public.<table>_bkp_20261125_1012

2026-11-25 10:12:12 [INFO] Approval skipped (--yes)
2026-11-25 10:12:12 [INFO] Starting pre-restore backups (psql): 3 table(s)
2026-11-25 10:12:12 [INFO] [salesdb] Backing up public.regions with psql -> public.regions_bkp_20261125_1012
2026-11-25 10:12:12 [INFO] [salesdb] psql copy OK: public.regions_bkp_20261125_1012 (6 rows)
2026-11-25 10:12:12 [INFO] [salesdb] Backing up sales.customers with psql -> public.customers_bkp_20261125_1012
2026-11-25 10:12:12 [INFO] [salesdb] psql copy OK: public.customers_bkp_20261125_1012 (40 rows)
2026-11-25 10:12:12 [INFO] [salesdb] Backing up sales.orders with psql -> public.orders_bkp_20261125_1012
2026-11-25 10:12:12 [INFO] [salesdb] psql copy OK: public.orders_bkp_20261125_1012 (500 rows)
2026-11-25 10:12:12 [INFO] Pre-restore backups finished OK (psql)
2026-11-25 10:12:12 [INFO] [salesdb] Starting restore (custom) <- /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:12 [INFO] [salesdb] Command: pg_restore -h db2.example.internal -p 5432 -U dba_admin -d salesdb --no-password --clean --if-exists --no-owner /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:12 [INFO] [salesdb] Restore finished in 0m00s
2026-11-25 10:12:12 [INFO] Pre-restore backups saved:
  [psql] db2.example.internal:5432/salesdb  public.regions_bkp_20261125_1012  (copy of public.regions, 6 rows)
  [psql] db2.example.internal:5432/salesdb  public.customers_bkp_20261125_1012  (copy of sales.customers, 40 rows)
  [psql] db2.example.internal:5432/salesdb  public.orders_bkp_20261125_1012  (copy of sales.orders, 500 rows)
2026-11-25 10:12:12 [INFO] Summary:
2026-11-25 10:12:12 [INFO]   DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
2026-11-25 10:12:12 [INFO]   salesdb                  OK        -          8.0K     0m00s    /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:12 [INFO] Run finished OK in 0m00s
```

---

## 6. The existing-table prompt
**When:** you run from a terminal, the target already has tables, and you did not pass `--backup-first` or `--force`. The wrapper asks `dump` / `psql` / `skip` / `cancel`, then asks you to type the target host name. This sample answers `dump` and then the host. `psql` takes in-database copies instead; `skip` requires typing `OVERWRITE N` (N is the table count) to restore with no backup; `cancel` stops the run. Unattended jobs (no terminal) are refused unless you pass `--backup-first`, `--force`, or `--yes` with a backup option.
```bash
./pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump \
  -d salesdb -h db2.example.internal -U dba_admin --clean --if-exists \
  -o /backups/restore-work
```
**Sample output:**
```
2026-11-25 10:12:12 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 10:12:13 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 10:12:13 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 10:12:13 [INFO] File map (1):
2026-11-25 10:12:13 [INFO]   salesdb_20261125_101209.dump -> salesdb  (8.0K, custom)
2026-11-25 10:12:13 [INFO] Checksum OK: salesdb_20261125_101209.dump
2026-11-25 10:12:13 [INFO] Connected: server_version_num=170012
2026-11-25 10:12:13 [WARN] 3 existing table(s) would be overwritten by this restore:
2026-11-25 10:12:13 [WARN]   db2.example.internal:5432/salesdb: public.regions, sales.customers, sales.orders
Back them up first? [dump / psql / skip / cancel]: 2026-11-25 10:12:13 [INFO] Answer: dump
2026-11-25 10:12:13 [INFO] Starting pre-restore backups (dump): 3 table(s)
2026-11-25 10:12:13 [INFO] [salesdb] Backing up public.regions, sales.customers, sales.orders with pg_dump_wrapper.sh
2026-11-25 10:12:13 [INFO] [salesdb] Command: bash /opt/pg-tools/pg_dump_wrapper.sh -h db2.example.internal -p 5432 -U dba_admin -d salesdb -F custom --checksum --table-sizes 0 --min-free-mb 1024 -o /backups/restore-work/pre_restore_backups/db2.example.internal_5432 --pgpassfile /home/dba/.pgpass -t \"public\".\"regions\" -t \"sales\".\"customers\" -t \"sales\".\"orders\"
2026-11-25 10:12:13 [INFO] [salesdb] pg_dump_wrapper.sh OK: /backups/restore-work/pre_restore_backups/db2.example.internal_5432/salesdb_20261125_101213.dump (8.0K, 0m00s)
2026-11-25 10:12:13 [INFO] Pre-restore backups finished OK (dump)

RESTORE SUMMARY
  Target     : db2.example.internal:5432  user=dba_admin
  Source     : /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump  (1 file(s), 8.0K)
  Files      : salesdb_20261125_101209.dump -> salesdb  (exists, 3 table(s) will be overwritten)
  Options    : --clean --if-exists --no-owner
  Checksums  : 1 OK
  Backup     : 3 table(s) already backed up (dump); locations are printed at the end

Type the target host name to continue (db2.example.internal), anything else cancels: 2026-11-25 10:12:13 [INFO] Answer: db2.example.internal
2026-11-25 10:12:13 [INFO] Approval accepted (db2.example.internal)
2026-11-25 10:12:13 [INFO] [salesdb] Starting restore (custom) <- /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:13 [INFO] [salesdb] Command: pg_restore -h db2.example.internal -p 5432 -U dba_admin -d salesdb --no-password --clean --if-exists --no-owner /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:13 [INFO] [salesdb] Restore finished in 0m00s
2026-11-25 10:12:13 [INFO] Pre-restore backups saved:
  [dump] db2.example.internal:5432/salesdb  /backups/restore-work/pre_restore_backups/db2.example.internal_5432/salesdb_20261125_101213.dump
2026-11-25 10:12:13 [INFO] Summary:
2026-11-25 10:12:13 [INFO]   DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
2026-11-25 10:12:13 [INFO]   salesdb                  OK        -          8.0K     0m00s    /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:13 [INFO] Run finished OK in 0m01s
```

---

## 7. One schema or table (or schema-only / data-only)
**When:** you only need one schema or table, not the whole dump. For `-n`, the wrapper runs `CREATE SCHEMA IF NOT EXISTS` first (pg_restore itself does not). `-s` restores definitions only; `-a` restores data only (the schema must already exist).
```bash
./pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump \
  -d sales_only -h db2.example.internal -U dba_admin --create -n sales -t orders --yes \
  -o /backups/restore-work
```
**Sample output:**
```
2026-11-25 10:12:13 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 10:12:13 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 10:12:13 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 10:12:13 [INFO] File map (1):
2026-11-25 10:12:13 [INFO]   salesdb_20261125_101209.dump -> sales_only  (8.0K, custom)
2026-11-25 10:12:13 [INFO] Checksum OK: salesdb_20261125_101209.dump
2026-11-25 10:12:13 [INFO] Connected: server_version_num=170012

RESTORE SUMMARY
  Target     : db2.example.internal:5432  user=dba_admin
  Source     : /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump  (1 file(s), 8.0K)
  Files      : salesdb_20261125_101209.dump -> sales_only  (new, will be created)
  Options    : --create -n sales -t orders --no-owner
  Checksums  : 1 OK
  Backup     : none needed (no existing tables will be overwritten)
  Schemas    : CREATE SCHEMA IF NOT EXISTS for: sales

2026-11-25 10:12:13 [INFO] Approval skipped (--yes)
2026-11-25 10:12:13 [INFO] [sales_only] Creating database sales_only (--create; it does not exist)
2026-11-25 10:12:14 [INFO] [sales_only] Ensuring schema(s) exist (-n): sales
2026-11-25 10:12:14 [INFO] [sales_only] Command: psql -X -w -q -v ON_ERROR_STOP=1 -h db2.example.internal -p 5432 -U dba_admin -d sales_only -c CREATE\ SCHEMA\ IF\ NOT\ EXISTS\ \"sales\"
2026-11-25 10:12:14 [INFO] [sales_only] Starting restore (custom) <- /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:14 [INFO] [sales_only] Command: pg_restore -h db2.example.internal -p 5432 -U dba_admin -d sales_only --no-password --schema=sales --table=orders --no-owner /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:14 [INFO] [sales_only] Restore finished in 0m01s
2026-11-25 10:12:14 [INFO] Summary:
2026-11-25 10:12:14 [INFO]   DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
2026-11-25 10:12:14 [INFO]   sales_only               OK        -          8.0K     0m01s    /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:14 [INFO] Run finished OK in 0m01s
```

Schema only, or data only:
```bash
./pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump \
  -d salesdb_empty -h db2.example.internal -U dba_admin --create -s --yes -o /backups/restore-work
./pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump \
  -d salesdb -h db2.example.internal -U dba_admin -a --backup-first --yes -o /backups/restore-work
```

---

## 8. Many servers with `--servers`
**When:** the same dumps should be restored to several hosts, one after another, with one summary. Host and port come from the file (`-h` / `-p` are rejected). A server that is down is recorded as `FAIL(2)` and the others continue; the run exits with the highest code. This sample also uses `--force` because `salesdb` already existed on the reachable server.
```bash
# /etc/pg_restore/servers.txt
# host,port,user,databases
db3.example.internal,5432,dba_admin,all
db2.example.internal,5432,dba_admin,salesdb,hrdb
```
```bash
./pg_restore_wrapper.sh --servers /etc/pg_restore/servers.txt \
  --from /backups/postgres/db1.example.internal_5432 \
  --map 'salesdb_*=salesdb' --map 'hrdb_*=hrdb' \
  --create --clean --if-exists --force --yes -o /backups/restore-work
```
**Sample output:**
```
2026-11-25 10:12:14 [INFO] ===== pg_restore_wrapper.sh v1.0.0: 2 server(s) from /etc/pg_restore/servers.txt: db3.example.internal:5432, db2.example.internal:5432 =====
2026-11-25 10:12:14 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 10:12:14 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 10:12:14 [INFO] Source /backups/postgres/db1.example.internal_5432: 2 dump file(s) selected, 1 older file(s) skipped
2026-11-25 10:12:14 [INFO] Skipping older dump (a newer file of the same dump is selected): /backups/postgres/db1.example.internal_5432/salesdb_20261117_010002.dump
2026-11-25 10:12:14 [INFO] File map (2):
2026-11-25 10:12:14 [INFO]   hrdb_20261125_101209.dir     -> hrdb  (12K, directory)
2026-11-25 10:12:14 [INFO]   salesdb_20261125_101209.dump -> salesdb  (8.0K, custom)
2026-11-25 10:12:14 [INFO] Checksum OK: hrdb_20261125_101209.dir
2026-11-25 10:12:14 [INFO] Checksum OK: salesdb_20261125_101209.dump
2026-11-25 10:12:14 [INFO] [db3.example.internal:5432] Server 1/2: user=dba_admin databases=all
2026-11-25 10:12:14 [ERROR] [db3.example.internal:5432] Server not accepting connections at db3.example.internal:5432 (pg_isready)
2026-11-25 10:12:14 [INFO] [db2.example.internal:5432] Server 2/2: user=dba_admin databases=salesdb,hrdb
2026-11-25 10:12:14 [INFO] [db2.example.internal:5432] Connected: server_version_num=170012
2026-11-25 10:12:14 [WARN] --force: 3 existing table(s) will be overwritten without a backup

RESTORE SUMMARY
  Targets    : 1 of 2 server(s) will be restored (/etc/pg_restore/servers.txt)
  Source     : /backups/postgres/db1.example.internal_5432  (2 file(s), 20K; 1 older file(s) skipped)
  Server 1   : db3.example.internal:5432  user=dba_admin  databases=all
               (unreachable - will not be restored)
  Server 2   : db2.example.internal:5432  user=dba_admin  databases=salesdb,hrdb
  Files      : hrdb_20261125_101209.dir     -> hrdb  (new, will be created)
               salesdb_20261125_101209.dump -> salesdb  (exists, 3 table(s) will be overwritten)
  Options    : --clean --if-exists --create --no-owner
  Checksums  : 2 OK
  Backup     : NONE - --force, 3 table(s) overwritten without a backup

2026-11-25 10:12:14 [INFO] Approval skipped (--yes)
2026-11-25 10:12:14 [INFO] [db2.example.internal:5432/hrdb] Creating database hrdb (--create; it does not exist)
2026-11-25 10:12:14 [INFO] [db2.example.internal:5432/hrdb] Starting restore (directory) <- /backups/postgres/db1.example.internal_5432/hrdb_20261125_101209.dir
2026-11-25 10:12:14 [INFO] [db2.example.internal:5432/hrdb] Command: pg_restore -h db2.example.internal -p 5432 -U dba_admin -d hrdb --no-password --clean --if-exists --no-owner /backups/postgres/db1.example.internal_5432/hrdb_20261125_101209.dir
2026-11-25 10:12:14 [INFO] [db2.example.internal:5432/hrdb] Restore finished in 0m00s
2026-11-25 10:12:14 [INFO] [db2.example.internal:5432/salesdb] Starting restore (custom) <- /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:14 [INFO] [db2.example.internal:5432/salesdb] Command: pg_restore -h db2.example.internal -p 5432 -U dba_admin -d salesdb --no-password --clean --if-exists --no-owner /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:14 [INFO] [db2.example.internal:5432/salesdb] Restore finished in 0m00s
2026-11-25 10:12:14 [INFO] Summary:
2026-11-25 10:12:14 [INFO]   SERVER/DATABASE          STATUS    STAGE      SIZE     TIME     FILE
2026-11-25 10:12:14 [INFO]   db3.example.internal:5432          FAIL(2)   precheck   -        0m00s    -
2026-11-25 10:12:14 [INFO]   db2.example.internal:5432/hrdb     OK        -          12K      0m00s    /backups/postgres/db1.example.internal_5432/hrdb_20261125_101209.dir
2026-11-25 10:12:14 [INFO]   db2.example.internal:5432/salesdb  OK        -          8.0K     0m00s    /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:14 [ERROR] Run finished with exit code 2 (stage: precheck (db3.example.internal:5432))
```

---

## 9. Test e-mail and webhook alerts
**When:** you have just configured mail or a webhook and want to prove delivery without restoring. `--alert-test` sends a `TEST` alert to every target and exits. A working MTA (`mail`, `mailx` or `sendmail`) is needed for e-mail; webhooks are posted with `curl`.
```bash
./pg_restore_wrapper.sh --alert-test \
  --alert-email dba@example.com --alert-from pg-restore@example.com \
  --alert-webhook https://hooks.slack.com/services/XXX/YYY/ZZZ \
  -o /backups/restore-work
```
**Sample output:**
```
2026-11-25 10:12:14 [INFO] Sending test alert...
2026-11-25 10:12:14 [INFO] Alert: e-mail sent to dba@example.com
2026-11-25 10:12:14 [INFO] Alert: webhook https://hooks.slack.com/... -> HTTP 200
```

---

## 10. Backup failed (exit 5)
**When:** a pre-restore backup fails. The restore is not started, the summary shows `FAIL(5)` at stage `backup` and a `SKIPPED` restore row, and the wrapper exits 5. The `[ERROR]` text after `exit 3` comes from `pg_dump_wrapper.sh`.
```bash
./pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump \
  -d salesdb -h db2.example.internal -U dba_admin --clean --if-exists --backup-first --yes \
  -o /backups/restore-work
```
**Sample output:**
```
2026-11-25 10:12:14 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 10:12:14 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 10:12:14 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 10:12:14 [INFO] File map (1):
2026-11-25 10:12:14 [INFO]   salesdb_20261125_101209.dump -> salesdb  (8.0K, custom)
2026-11-25 10:12:14 [INFO] Checksum OK: salesdb_20261125_101209.dump
2026-11-25 10:12:14 [INFO] Connected: server_version_num=170012

RESTORE SUMMARY
  Target     : db2.example.internal:5432  user=dba_admin
  Source     : /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump  (1 file(s), 8.0K)
  Files      : salesdb_20261125_101209.dump -> salesdb  (exists, 3 table(s) will be overwritten)
  Options    : --clean --if-exists --no-owner
  Checksums  : 1 OK
  Backup     : 3 table(s) via pg_dump_wrapper.sh -> /backups/restore-work/pre_restore_backups/

2026-11-25 10:12:14 [INFO] Approval skipped (--yes)
2026-11-25 10:12:15 [INFO] Starting pre-restore backups (dump): 3 table(s)
2026-11-25 10:12:15 [INFO] [salesdb] Backing up public.regions, sales.customers, sales.orders with pg_dump_wrapper.sh
2026-11-25 10:12:15 [INFO] [salesdb] Command: bash /opt/pg-tools/pg_dump_wrapper.sh -h db2.example.internal -p 5432 -U dba_admin -d salesdb -F custom --checksum --table-sizes 0 --min-free-mb 1024 -o /backups/restore-work/pre_restore_backups/db2.example.internal_5432 --pgpassfile /home/dba/.pgpass -t \"public\".\"regions\" -t \"sales\".\"customers\" -t \"sales\".\"orders\"
2026-11-25 10:12:15 [ERROR] [salesdb] pg_dump_wrapper.sh failed (exit 3): [ERROR] simulated backup failure 
2026-11-25 10:12:15 [ERROR] Pre-restore backup failed; no restore was started.
2026-11-25 10:12:15 [INFO] Summary:
2026-11-25 10:12:15 [INFO]   DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
2026-11-25 10:12:15 [INFO]   salesdb                  FAIL(5)   backup     -        0m00s    -
2026-11-25 10:12:15 [INFO]   salesdb                  SKIPPED   -          8.0K     -        /backups/postgres/db1.example.internal_5432/salesdb_20261125_101209.dump
2026-11-25 10:12:15 [ERROR] Run finished with exit code 5 (stage: backup)
```

---

## 11. Exit codes

| Code | Meaning |
|---|---|
| 0 | Everything restored |
| 1 | Usage / configuration error |
| 2 | Pre-check failed, refused (no approval, no terminal, unmapped file, existing tables without a backup) or cancelled |
| 3 | A restore failed |
| 4 | Checksum mismatch |
| 5 | A pre-restore backup failed (nothing was restored) |
| 130 | Interrupted (Ctrl-C / TERM) |

Multi-file and multi-server runs exit with the highest code of any row. In a script:
```bash
./pg_restore_wrapper.sh --from /backups/salesdb_20261125_101209.dump -d salesdb \
  -h db2.example.internal -U dba_admin --clean --if-exists --backup-first --yes
rc=$?
case $rc in
  0) echo "restore OK" ;;
  5) echo "backup failed, nothing was restored"; exit 5 ;;
  *) echo "restore failed (rc=$rc), see the log"; exit "$rc" ;;
esac
```
