# pg_restore_wrapper.sh examples

Copy-paste recipes. Host names, paths and data are examples. Every command below asks for approval (type the host name) unless it has `--yes`. Add `--dry-run` first to see the plan and the exact commands without changing anything.

Contents: [Basics](#basics) · [Folders and mapping](#folders-and-mapping) · [Existing tables](#existing-tables) · [Aurora / RDS](#aurora--rds) · [Plain SQL dumps](#plain-sql-dumps) · [Many servers](#many-servers) · [Config file and cron](#config-file-and-cron) · [Alerts](#alerts) · [Rollback](#rollback) · [Exit codes in scripts](#exit-codes-in-scripts) · [Real output](#real-output)

## Basics

Restore one dump into an existing database and replace its objects:
```bash
pg_restore_wrapper.sh --from /backups/salesdb_20261124_010015.dump -d salesdb \
  -h db2.example.internal -U dba_admin --clean --if-exists --backup-first
```

Restore into a new database (created only if it does not exist yet), 4 parallel jobs:
```bash
pg_restore_wrapper.sh --from /backups/salesdb_20261124_010015.dump -d salesdb_copy \
  -h db2.example.internal -U dba_admin --create -j 4
```

A directory-format dump works the same way:
```bash
pg_restore_wrapper.sh --from /backups/hrdb_20261124_010018.dir -d hrdb -h db2.example.internal --create -j 8
```

Only one schema or table. For `-n`, the wrapper runs `CREATE SCHEMA IF NOT EXISTS` first (pg_restore itself does not):
```bash
pg_restore_wrapper.sh --from /backups/salesdb_20261124_010015.dump -d salesdb -h db2.example.internal \
  -n sales --clean --if-exists --backup-first
pg_restore_wrapper.sh --from /backups/salesdb_20261124_010015.dump -d salesdb -h db2.example.internal \
  -t orders -t customers --clean --if-exists --backup-first=psql
```

Schema only, or data only:
```bash
pg_restore_wrapper.sh --from /backups/salesdb_20261124_010015.dump -d salesdb_empty -h db2.example.internal --create -s
pg_restore_wrapper.sh --from /backups/salesdb_20261124_010015.dump -d salesdb -h db2.example.internal -a --backup-first
```

Pass anything else straight to pg_restore after `--`:
```bash
pg_restore_wrapper.sh --from /backups/salesdb.dump -d salesdb -h db2.example.internal -- --disable-triggers
```

## Folders and mapping

Nothing is guessed from file names. Map each file (or glob) to a database:
```bash
pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432 \
  --map 'salesdb_*=salesdb' --map 'hrdb_*=hrdb' \
  -h db2.example.internal -U dba_admin --create --clean --if-exists -j 4
```

Restore to different names (a refresh into a copy):
```bash
pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432 \
  --map 'salesdb_*=salesdb_uat' --map 'hrdb_*=hrdb_uat' -h uat.example.internal --create --clean --if-exists
```

Keep the mapping in a file:
```bash
cat > /etc/pg_restore/map.txt <<'MAP'
# FILE=DB  (name or shell glob; first match wins)
salesdb_*=salesdb_uat
hrdb_*=hrdb_uat
MAP
pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432 --map-file /etc/pg_restore/map.txt -h uat.example.internal --create
```

Only some files from a folder. A selected file with no mapping stops the run (exit 2), so exclude the ones you don't want:
```bash
pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432 --include 'salesdb_*' --map 'salesdb_*=salesdb' -h db2.example.internal
pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432 --exclude 'hrdb_*'    --map 'salesdb_*=salesdb' -h db2.example.internal
```

Several dates of the same dump in the folder: the newest is used and the older ones are logged as skipped. Pin an older one with `--include`:
```bash
pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432 \
  --include 'salesdb_20261117_*' --map 'salesdb_*=salesdb' -h db2.example.internal --clean --if-exists --backup-first
```

## Existing tables

Tables in the dump that already exist in the target are never overwritten silently.
If any exist and `--clean` is not set, the run refuses with exit 2 (unless you pass `--data-only`). Use `--clean --if-exists` for a full replace.

```bash
# back them up with pg_dump_wrapper.sh (default method) after approval
pg_restore_wrapper.sh --from salesdb.dump -d salesdb -h db2.example.internal --clean --if-exists --backup-first
# copy them in the same database: public.orders_bkp_20261125_0130, ...
pg_restore_wrapper.sh --from salesdb.dump -d salesdb -h db2.example.internal --clean --if-exists --backup-first=psql
# copies into their own schema
pg_restore_wrapper.sh --from salesdb.dump -d salesdb -h db2.example.internal --clean --if-exists --backup-first=psql --backup-schema bk_restore
# no backup at all (the summary says NONE - --force)
pg_restore_wrapper.sh --from salesdb.dump -d salesdb -h db2.example.internal --clean --if-exists --force
```

Without any of these, on a terminal you get a warning and a question:
```
[WARN] 3 existing table(s) would be overwritten by this restore:
[WARN]   db2.example.internal:5432/salesdb: public.regions, sales.customers, sales.orders
Back them up first? [dump / psql / skip / cancel]:
```
- `dump` or `psql`: the backup is taken now, then you see the summary and approve.
- `skip`: type `OVERWRITE 3` to confirm.
- `cancel` or anything else: stops (exit 2).

With `--yes` or in cron, the run refuses (exit 2) and prints the `pg_dump_wrapper.sh` command you could run first.

If any backup fails, no restore starts (exit 5).

## Aurora / RDS

The master user is not a superuser, so it cannot set object owners to other roles. `--no-owner` is the default (and you usually also want `-x`):
```bash
pg_restore_wrapper.sh --from salesdb.dump -d salesdb -h mycluster.cluster-abc123.ap-south-1.rds.amazonaws.com \
  -U dba_admin --pgpassfile ~/.pgpass --create --clean --if-exists --no-privileges --backup-first
```
`--keep-owner` turns the default off. That usually fails with `must be able to SET ROLE "postgres"`, and the wrapper prints a hint to drop `--keep-owner` or use `--role`.

Restore as the application owner so the new objects belong to it:
```bash
pg_restore_wrapper.sh --from salesdb.dump -d salesdb -h db2.example.internal -U dba_admin --no-owner --role app_owner --clean --if-exists --backup-first
```
`--role` is also used for `CREATE DATABASE` and for the psql backup copies.

## Plain SQL dumps

`.sql` and `.sql.gz` go through `psql -v ON_ERROR_STOP=1` (with `gzip -dc` for `.gz`):
```bash
pg_restore_wrapper.sh --from /backups/plaindb_20261124_010000.sql    -d plaindb -h db2.example.internal --create --no-owner
pg_restore_wrapper.sh --from /backups/plaindb_20261124_010000.sql.gz -d plaindb -h db2.example.internal --create --no-owner --no-privileges
```
For plain dumps, `-O` drops `ALTER ... OWNER TO ...;` lines and `-x` drops `GRANT`/`REVOKE` lines. `-j`, `-c`, `-n`, `-t`, `-s`, `-a` do not apply: make the dump with the options you need (`pg_dump_wrapper.sh -F plain --clean --if-exists ...`).

## Many servers

`servers.txt`:
```
# host,port,user,databases
db1.example.internal,5432,dba_admin,all
db2.example.internal,5432,dba_admin,salesdb
db3.example.internal,5433,,all
```
`databases` = `all`, or a comma list of the target databases to restore on that server. An empty user means `-U`.
```bash
pg_restore_wrapper.sh --servers /etc/pg_restore/servers.txt --pgpassfile /etc/pg_restore/.pgpass \
  --from /backups/salesdb_20261124_010015.dump -d salesdb --clean --if-exists --no-owner --backup-first=psql
```
- Approval is `RESTORE N`, where N counts the reachable servers. A down server is a `FAIL(2) precheck` row, and the others still run.
- All backups on all servers run before any restore.
- `-h`, `-p` and `-W` are not allowed with `--servers`. Use one pgpass line per `host:port`.

## Config file and cron

```bash
cp pg_restore_wrapper.conf.example /etc/pg_restore/pg_restore_wrapper.conf   # edit it
pg_restore_wrapper.sh --config /etc/pg_restore/pg_restore_wrapper.conf --from /backups/salesdb.dump -d salesdb --dry-run
```

A nightly refresh of a UAT copy. Cron has no terminal, so it needs `--yes`, and existing tables need `backup_first=` or `--force`:
```
30 2 * * * /opt/pg-tools/pg_restore_wrapper.sh --config /etc/pg_restore/uat.conf --yes >>/var/log/pg_restore_cron.log 2>&1
```
Without `--yes` a cron run refuses with exit 2. The RESTORE SUMMARY is still written to the log.

## Alerts

```bash
pg_restore_wrapper.sh --alert-webhook https://hooks.slack.com/services/T000/B000/XXXX --alert-test
pg_restore_wrapper.sh --from salesdb.dump -d salesdb -h db2.example.internal --backup-first --yes \
  --alert-email dba@example.com --alert-webhook https://example.com/hook --alert-webhook-format json --alert-on always
```
Alerts go out on failure by default. A run cancelled at a prompt sends no alert, and alerts never change the exit code.

## Rollback

Every run with a backup prints rollback commands at the end and saves them as a script:
```
[INFO] Rollback commands saved (review, then run with bash): /backups/restore-work/rollback_20261125_013012.sh
```
- dump method: a `pg_restore_wrapper.sh --from <backup file> -d DB --clean --if-exists --force` command. It asks for approval again.
- psql method: `TRUNCATE` + `INSERT ... SELECT` from the `_bkp_` copy in one transaction, plus a commented `DROP TABLE` for later. If other tables in the same backup reference a copied table, they are truncated together. If a table outside the backup references it, the script warns, recommends the dump method, and only comments a `TRUNCATE ... CASCADE` alternative (that would also empty those referencing tables).

Read the file, then run it with `bash /backups/restore-work/rollback_20261125_013012.sh`.

## Exit codes in scripts

```bash
pg_restore_wrapper.sh --config /etc/pg_restore/uat.conf --yes
case $? in
  0) echo "restored" ;;
  2) echo "refused or pre-check failed: nothing was restored" ;;
  3) echo "a restore failed: check the log and the rollback file" ;;
  4) echo "checksum mismatch" ;;
  5) echo "pre-restore backup failed: nothing was restored" ;;
  *) echo "other error" ;;
esac
```

## Real output

The runs below are real (PostgreSQL 17, non-superuser login) with fake host names and paths substituted afterwards.

Note: sections 5 and 5c were captured when a missing `--clean` only warned and then let pg_restore fail. The wrapper now **refuses with exit 2** in that situation (unless `--data-only` is set), so you will not see a restore start without `--clean`. `--no-owner` is also the default now, even if you omit it from the command line.

```text
------------------------------------------------------------------------------
1) --dry-run of a folder (newest dump per database, file map, checksums, existing-table warning)
------------------------------------------------------------------------------
$ pg_restore_wrapper.sh --from /backups/postgres/db1.example.internal_5432 --map 'salesdb_*=salesdb' --map 'hrdb_*=hrdb' -h db2.example.internal -U dba_admin --create --clean --if-exists --no-owner --no-privileges -j 4 --dry-run -o /backups/restore-work
2026-11-25 04:54:05 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 04:54:05 [INFO] DRY RUN - nothing will be created, backed up or restored
2026-11-25 04:54:05 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 04:54:05 [INFO] Source /backups/postgres/db1.example.internal_5432: 2 dump file(s) selected, 1 older file(s) skipped
2026-11-25 04:54:05 [INFO] Skipping older dump (a newer file of the same dump is selected): /backups/postgres/db1.example.internal_5432/salesdb_20261117_010002.dump
2026-11-25 04:54:05 [INFO] File map (2):
2026-11-25 04:54:05 [INFO]   hrdb_20261125_045405.dump    -> hrdb  (4.0K, custom)
2026-11-25 04:54:05 [INFO]   salesdb_20261125_045405.dump -> salesdb  (8.0K, custom)
2026-11-25 04:54:05 [INFO] Checksum OK: hrdb_20261125_045405.dump
2026-11-25 04:54:05 [INFO] Checksum OK: salesdb_20261125_045405.dump
2026-11-25 04:54:05 [INFO] Connected: server_version_num=170012
2026-11-25 04:54:05 [WARN] 3 existing table(s) would be overwritten by this restore:
2026-11-25 04:54:05 [WARN]   db2.example.internal:5432/salesdb: public.regions, sales.customers, sales.orders
2026-11-25 04:54:05 [INFO] DRY RUN - would ask: back them up first? [dump / psql / skip / cancel]

RESTORE SUMMARY
  Target     : db2.example.internal:5432  user=dba_admin
  Source     : /backups/postgres/db1.example.internal_5432  (2 file(s), 12K; 1 older file(s) skipped)
  Files      : hrdb_20261125_045405.dump    -> hrdb  (new, will be created)
               salesdb_20261125_045405.dump -> salesdb  (exists, 3 table(s) will be overwritten)
  Options    : --clean --if-exists --create -j 4 --no-owner --no-privileges
  Checksums  : 2 OK
  Backup     : 3 table(s) via pg_dump_wrapper.sh -> /backups/restore-work/pre_restore_backups/

2026-11-25 04:54:05 [INFO] DRY RUN - pre-restore backup (dump) would run:
bash /opt/pg-tools/pg_dump_wrapper.sh -h db2.example.internal -p 5432 -U dba_admin -d salesdb -F custom --checksum --table-sizes 0 --min-free-mb 1 -o /backups/restore-work/pre_restore_backups/db2.example.internal_5432 --pgpassfile /home/dba/.pgpass -t \"public\".\"regions\" -t \"sales\".\"customers\" -t \"sales\".\"orders\"
2026-11-25 04:54:05 [INFO] DRY RUN - restore commands:
psql -X -w -q -v ON_ERROR_STOP=1 -h db2.example.internal -p 5432 -U dba_admin -d postgres -c CREATE\ DATABASE\ \"hrdb\"
pg_restore -h db2.example.internal -p 5432 -U dba_admin -d hrdb --no-password --jobs=4 --clean --if-exists --no-owner --no-privileges /backups/postgres/db1.example.internal_5432/hrdb_20261125_045405.dump
pg_restore -h db2.example.internal -p 5432 -U dba_admin -d salesdb --no-password --jobs=4 --clean --if-exists --no-owner --no-privileges /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump
2026-11-25 04:54:05 [INFO] DRY RUN - approval would be required: type db2.example.internal


------------------------------------------------------------------------------
2) Same restore by hand: existing-table prompt (answer: psql), RESTORE SUMMARY, host-name approval, rollback
------------------------------------------------------------------------------
$ same command, no --dry-run, run by hand (answers: psql, then the host name)
psql
db2.example.internal
2026-11-25 04:54:05 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 04:54:05 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 04:54:05 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 04:54:05 [INFO] Free space in /backups/restore-work: 123577 MB
2026-11-25 04:54:05 [INFO] Source /backups/postgres/db1.example.internal_5432: 2 dump file(s) selected, 1 older file(s) skipped
2026-11-25 04:54:05 [INFO] Skipping older dump (a newer file of the same dump is selected): /backups/postgres/db1.example.internal_5432/salesdb_20261117_010002.dump
2026-11-25 04:54:05 [INFO] File map (2):
2026-11-25 04:54:05 [INFO]   hrdb_20261125_045405.dump    -> hrdb  (4.0K, custom)
2026-11-25 04:54:05 [INFO]   salesdb_20261125_045405.dump -> salesdb  (8.0K, custom)
2026-11-25 04:54:06 [INFO] Checksum OK: hrdb_20261125_045405.dump
2026-11-25 04:54:06 [INFO] Checksum OK: salesdb_20261125_045405.dump
2026-11-25 04:54:06 [INFO] Connected: server_version_num=170012
2026-11-25 04:54:06 [WARN] 3 existing table(s) would be overwritten by this restore:
2026-11-25 04:54:06 [WARN]   db2.example.internal:5432/salesdb: public.regions, sales.customers, sales.orders
Back them up first? [dump / psql / skip / cancel]: 2026-11-25 04:54:06 [INFO] Answer: psql
2026-11-25 04:54:06 [INFO] Starting pre-restore backups (psql): 3 table(s)
2026-11-25 04:54:06 [INFO] [salesdb] Backing up public.regions with psql -> public.regions_bkp_20261125_0454
2026-11-25 04:54:06 [INFO] [salesdb] psql copy OK: public.regions_bkp_20261125_0454 (2 rows)
2026-11-25 04:54:06 [INFO] [salesdb] Backing up sales.customers with psql -> public.customers_bkp_20261125_0454
2026-11-25 04:54:06 [INFO] [salesdb] psql copy OK: public.customers_bkp_20261125_0454 (40 rows)
2026-11-25 04:54:06 [INFO] [salesdb] Backing up sales.orders with psql -> public.orders_bkp_20261125_0454
2026-11-25 04:54:06 [INFO] [salesdb] psql copy OK: public.orders_bkp_20261125_0454 (500 rows)
2026-11-25 04:54:06 [INFO] Pre-restore backups finished OK (psql)

RESTORE SUMMARY
  Target     : db2.example.internal:5432  user=dba_admin
  Source     : /backups/postgres/db1.example.internal_5432  (2 file(s), 12K; 1 older file(s) skipped)
  Files      : hrdb_20261125_045405.dump    -> hrdb  (new, will be created)
               salesdb_20261125_045405.dump -> salesdb  (exists, 3 table(s) will be overwritten)
  Options    : --clean --if-exists --create -j 4 --no-owner --no-privileges
  Checksums  : 2 OK
  Backup     : 3 table(s) already backed up (psql); rollback commands are printed at the end

Type the target host name to continue (db2.example.internal), anything else cancels: 2026-11-25 04:54:06 [INFO] Answer: db2.example.internal
2026-11-25 04:54:06 [INFO] Approval accepted (db2.example.internal)
2026-11-25 04:54:06 [INFO] [hrdb] Creating database hrdb (--create; it does not exist)
2026-11-25 04:54:06 [INFO] [hrdb] Starting restore (custom) <- /backups/postgres/db1.example.internal_5432/hrdb_20261125_045405.dump
2026-11-25 04:54:06 [INFO] [hrdb] Command: pg_restore -h db2.example.internal -p 5432 -U dba_admin -d hrdb --no-password --jobs=4 --clean --if-exists --no-owner --no-privileges /backups/postgres/db1.example.internal_5432/hrdb_20261125_045405.dump
2026-11-25 04:54:06 [INFO] [hrdb] Restore finished in 0m00s
2026-11-25 04:54:06 [INFO] [salesdb] Starting restore (custom) <- /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump
2026-11-25 04:54:06 [INFO] [salesdb] Command: pg_restore -h db2.example.internal -p 5432 -U dba_admin -d salesdb --no-password --jobs=4 --clean --if-exists --no-owner --no-privileges /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump
2026-11-25 04:54:06 [INFO] [salesdb] Restore finished in 0m00s
2026-11-25 04:54:06 [INFO] Rollback commands (from the pre-restore backup):
# db2.example.internal:5432/salesdb public.regions  (psql copy -> public.regions_bkp_20261125_0454, 2 rows)
psql -h db2.example.internal -p 5432 -U dba_admin -d salesdb -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
TRUNCATE "public"."regions";
INSERT INTO "public"."regions" (id, name) OVERRIDING SYSTEM VALUE SELECT id, name FROM "public"."regions_bkp_20261125_0454";
COMMIT;
-- when no longer needed: DROP TABLE "public"."regions_bkp_20261125_0454";
SQL

# db2.example.internal:5432/salesdb sales.customers  (psql copy -> public.customers_bkp_20261125_0454, 40 rows)
psql -h db2.example.internal -p 5432 -U dba_admin -d salesdb -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
TRUNCATE "sales"."customers";
INSERT INTO "sales"."customers" (id, name) OVERRIDING SYSTEM VALUE SELECT id, name FROM "public"."customers_bkp_20261125_0454";
COMMIT;
-- when no longer needed: DROP TABLE "public"."customers_bkp_20261125_0454";
SQL

# db2.example.internal:5432/salesdb sales.orders  (psql copy -> public.orders_bkp_20261125_0454, 500 rows)
psql -h db2.example.internal -p 5432 -U dba_admin -d salesdb -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
TRUNCATE "sales"."orders";
INSERT INTO "sales"."orders" (id, amount, note) OVERRIDING SYSTEM VALUE SELECT id, amount, note FROM "public"."orders_bkp_20261125_0454";
COMMIT;
-- when no longer needed: DROP TABLE "public"."orders_bkp_20261125_0454";
SQL
2026-11-25 04:54:06 [INFO] Rollback commands saved (review, then run with bash): /backups/restore-work/rollback_20261125_045406.sh
2026-11-25 04:54:06 [INFO] Summary:
2026-11-25 04:54:06 [INFO]   DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
2026-11-25 04:54:06 [INFO]   hrdb                     OK        -          4.0K     0m00s    /backups/postgres/db1.example.internal_5432/hrdb_20261125_045405.dump
2026-11-25 04:54:06 [INFO]   salesdb                  OK        -          8.0K     0m00s    /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump
2026-11-25 04:54:06 [INFO] Run finished OK in 0m01s


------------------------------------------------------------------------------
3) Single file with --backup-first (dump via pg_dump_wrapper.sh) and --yes
------------------------------------------------------------------------------
$ pg_restore_wrapper.sh --from .../salesdb_20261125_045407.dump -d salesdb -h db2.example.internal -U dba_admin --clean --if-exists --backup-first --no-owner --no-privileges --yes -o /backups/restore-work
2026-11-25 04:54:06 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 04:54:06 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 04:54:06 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 04:54:06 [INFO] Free space in /backups/restore-work: 123575 MB
2026-11-25 04:54:06 [INFO] File map (1):
2026-11-25 04:54:06 [INFO]   salesdb_20261125_045405.dump -> salesdb  (8.0K, custom)
2026-11-25 04:54:06 [INFO] Checksum OK: salesdb_20261125_045405.dump
2026-11-25 04:54:06 [INFO] Connected: server_version_num=170012

RESTORE SUMMARY
  Target     : db2.example.internal:5432  user=dba_admin
  Source     : /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump  (1 file(s), 8.0K)
  Files      : salesdb_20261125_045405.dump -> salesdb  (exists, 3 table(s) will be overwritten)
  Options    : --clean --if-exists --no-owner --no-privileges
  Checksums  : 1 OK
  Backup     : 3 table(s) via pg_dump_wrapper.sh -> /backups/restore-work/pre_restore_backups/

2026-11-25 04:54:06 [INFO] Approval skipped (--yes)
2026-11-25 04:54:06 [INFO] Starting pre-restore backups (dump): 3 table(s)
2026-11-25 04:54:06 [INFO] [salesdb] Backing up public.regions, sales.customers, sales.orders with pg_dump_wrapper.sh
2026-11-25 04:54:06 [INFO] [salesdb] Command: bash /opt/pg-tools/pg_dump_wrapper.sh -h db2.example.internal -p 5432 -U dba_admin -d salesdb -F custom --checksum --table-sizes 0 --min-free-mb 1 -o /backups/restore-work/pre_restore_backups/db2.example.internal_5432 --pgpassfile /home/dba/.pgpass -t \"public\".\"regions\" -t \"sales\".\"customers\" -t \"sales\".\"orders\"
2026-11-25 04:54:07 [INFO] [salesdb] pg_dump_wrapper.sh OK: /backups/restore-work/pre_restore_backups/db2.example.internal_5432/salesdb_20261125_045407.dump (8.0K, 0m01s)
2026-11-25 04:54:07 [INFO] Pre-restore backups finished OK (dump)
2026-11-25 04:54:07 [INFO] [salesdb] Starting restore (custom) <- /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump
2026-11-25 04:54:07 [INFO] [salesdb] Command: pg_restore -h db2.example.internal -p 5432 -U dba_admin -d salesdb --no-password --clean --if-exists --no-owner --no-privileges /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump
2026-11-25 04:54:07 [INFO] [salesdb] Restore finished in 0m00s
2026-11-25 04:54:07 [INFO] Rollback commands (from the pre-restore backup):
# db2.example.internal:5432/salesdb  (pg_dump_wrapper.sh backup -> /backups/restore-work/pre_restore_backups/db2.example.internal_5432/salesdb_20261125_045407.dump)
bash /opt/pg-tools/pg_restore_wrapper.sh -h db2.example.internal -p 5432 -U dba_admin --from /backups/restore-work/pre_restore_backups/db2.example.internal_5432/salesdb_20261125_045407.dump -d salesdb --clean --if-exists --force
2026-11-25 04:54:07 [INFO] Rollback commands saved (review, then run with bash): /backups/restore-work/rollback_20261125_045407.sh
2026-11-25 04:54:07 [INFO] Summary:
2026-11-25 04:54:07 [INFO]   DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
2026-11-25 04:54:07 [INFO]   salesdb                  OK        -          8.0K     0m00s    /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump
2026-11-25 04:54:07 [INFO] Run finished OK in 0m01s


------------------------------------------------------------------------------
4) The rollback file written by section 3
------------------------------------------------------------------------------
$ rollback file written by section 3
#!/usr/bin/env bash
# Rollback for the pg_restore_wrapper run started 2026-11-25 04:54:06. Review before running: bash /backups/restore-work/rollback_20261125_045407.sh
set -e

# db2.example.internal:5432/salesdb  (pg_dump_wrapper.sh backup -> /backups/restore-work/pre_restore_backups/db2.example.internal_5432/salesdb_20261125_045407.dump)
bash /opt/pg-tools/pg_restore_wrapper.sh -h db2.example.internal -p 5432 -U dba_admin --from /backups/restore-work/pre_restore_backups/db2.example.internal_5432/salesdb_20261125_045407.dump -d salesdb --clean --if-exists --force


------------------------------------------------------------------------------
5) Cron / no terminal: existing tables without --backup-first or --force -> refused (exit 2)
------------------------------------------------------------------------------
$ cron / no terminal, existing tables, no --backup-first or --force
2026-11-25 04:54:07 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 04:54:07 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 04:54:07 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 04:54:07 [INFO] Free space in /backups/restore-work: 123575 MB
2026-11-25 04:54:07 [INFO] File map (1):
2026-11-25 04:54:07 [INFO]   salesdb_20261125_045405.dump -> salesdb  (8.0K, custom)
2026-11-25 04:54:07 [INFO] Checksum OK: salesdb_20261125_045405.dump
2026-11-25 04:54:07 [INFO] Connected: server_version_num=170012
2026-11-25 04:54:07 [WARN] --clean is not set: restoring over existing tables gives 'already exists' / duplicate key errors (FAIL(3)) and can add rows to the old data. For a full replace add --clean --if-exists.
2026-11-25 04:54:07 [WARN] 3 existing table(s) would be overwritten by this restore:
2026-11-25 04:54:07 [WARN]   db2.example.internal:5432/salesdb: public.regions, sales.customers, sales.orders
2026-11-25 04:54:07 [INFO] Back them up first, for example:
bash /opt/pg-tools/pg_dump_wrapper.sh -h db2.example.internal -p 5432 -U dba_admin -d salesdb -F custom --checksum --table-sizes 0 --min-free-mb 1 -o /backups/restore-work/pre_restore_backups/db2.example.internal_5432 --pgpassfile /home/dba/.pgpass -t \"public\".\"regions\" -t \"sales\".\"customers\" -t \"sales\".\"orders\"
2026-11-25 04:54:07 [INFO] or re-run with --backup-first (dump), --backup-first=psql, or --force to skip the backup.
2026-11-25 04:54:07 [ERROR] 3 existing table(s) would be overwritten and neither --backup-first nor --force was given (--yes never overwrites tables without a backup). Nothing was restored.
2026-11-25 04:54:07 [ERROR] Run finished with exit code 2 (stage: precheck)


------------------------------------------------------------------------------
5b) A selected file with no --map -> refused (exit 2)
------------------------------------------------------------------------------
$ a selected file with no --map
2026-11-25 04:54:07 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 04:54:07 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 04:54:07 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 04:54:07 [INFO] Free space in /backups/restore-work: 123575 MB
2026-11-25 04:54:07 [INFO] Source /backups/postgres/db1.example.internal_5432: 2 dump file(s) selected, 1 older file(s) skipped
2026-11-25 04:54:07 [INFO] Skipping older dump (a newer file of the same dump is selected): /backups/postgres/db1.example.internal_5432/salesdb_20261117_010002.dump
2026-11-25 04:54:07 [ERROR] No --map for selected file: hrdb_20261125_045405.dump
2026-11-25 04:54:07 [ERROR] 1 selected file(s) have no target database. Add --map 'FILE=DB' (globs allowed) or a --map-file line for each, or leave them out with --exclude. Nothing was restored.
2026-11-25 04:54:07 [ERROR] Run finished with exit code 2 (stage: precheck)


------------------------------------------------------------------------------
5c) One file fails (salesdb without --clean), the other continues (hrdb_new)
------------------------------------------------------------------------------
$ one file fails, the other continues: --map 'hrdb_*=hrdb_new' --create, salesdb without --clean, --force
2026-11-25 04:54:07 [INFO] ===== pg_restore_wrapper.sh v1.0.0: host=db2.example.internal port=5432 user=dba_admin =====
2026-11-25 04:54:07 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 04:54:07 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 04:54:07 [INFO] Free space in /backups/restore-work: 123575 MB
2026-11-25 04:54:07 [INFO] Source /backups/postgres/db1.example.internal_5432: 2 dump file(s) selected, 1 older file(s) skipped
2026-11-25 04:54:07 [INFO] Skipping older dump (a newer file of the same dump is selected): /backups/postgres/db1.example.internal_5432/salesdb_20261117_010002.dump
2026-11-25 04:54:07 [INFO] File map (2):
2026-11-25 04:54:07 [INFO]   hrdb_20261125_045405.dump    -> hrdb_new  (4.0K, custom)
2026-11-25 04:54:07 [INFO]   salesdb_20261125_045405.dump -> salesdb  (8.0K, custom)
2026-11-25 04:54:07 [INFO] Checksum OK: hrdb_20261125_045405.dump
2026-11-25 04:54:07 [INFO] Checksum OK: salesdb_20261125_045405.dump
2026-11-25 04:54:07 [INFO] Connected: server_version_num=170012
2026-11-25 04:54:07 [WARN] --clean is not set: restoring over existing tables gives 'already exists' / duplicate key errors (FAIL(3)) and can add rows to the old data. For a full replace add --clean --if-exists.
2026-11-25 04:54:07 [WARN] --force: 3 existing table(s) will be overwritten without a backup

RESTORE SUMMARY
  Target     : db2.example.internal:5432  user=dba_admin
  Source     : /backups/postgres/db1.example.internal_5432  (2 file(s), 12K; 1 older file(s) skipped)
  Files      : hrdb_20261125_045405.dump    -> hrdb_new  (new, will be created)
               salesdb_20261125_045405.dump -> salesdb  (exists, 3 table(s) will be overwritten)
  Options    : --create --no-owner --no-privileges
  Checksums  : 2 OK
  Backup     : NONE - --force, 3 table(s) overwritten without a backup

2026-11-25 04:54:07 [INFO] Approval skipped (--yes)
2026-11-25 04:54:07 [INFO] [hrdb_new] Creating database hrdb_new (--create; it does not exist)
2026-11-25 04:54:07 [INFO] [hrdb_new] Starting restore (custom) <- /backups/postgres/db1.example.internal_5432/hrdb_20261125_045405.dump
2026-11-25 04:54:07 [INFO] [hrdb_new] Command: pg_restore -h db2.example.internal -p 5432 -U dba_admin -d hrdb_new --no-password --no-owner --no-privileges /backups/postgres/db1.example.internal_5432/hrdb_20261125_045405.dump
2026-11-25 04:54:07 [INFO] [hrdb_new] Restore finished in 0m00s
2026-11-25 04:54:07 [INFO] [salesdb] Starting restore (custom) <- /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump
2026-11-25 04:54:07 [INFO] [salesdb] Command: pg_restore -h db2.example.internal -p 5432 -U dba_admin -d salesdb --no-password --no-owner --no-privileges /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump
2026-11-25 04:54:07 [ERROR] [salesdb] pg_restore: error: could not execute query: ERROR:  schema "sales" already exists
2026-11-25 04:54:07 [INFO] [salesdb] Command was: CREATE SCHEMA sales;
2026-11-25 04:54:07 [ERROR] [salesdb] pg_restore: error: could not execute query: ERROR:  relation "regions" already exists
2026-11-25 04:54:07 [INFO] [salesdb] Command was: CREATE TABLE public.regions (
2026-11-25 04:54:07 [INFO] [salesdb]     id integer,
2026-11-25 04:54:07 [INFO] [salesdb]     name text
2026-11-25 04:54:07 [INFO] [salesdb] );
2026-11-25 04:54:07 [ERROR] [salesdb] pg_restore: error: could not execute query: ERROR:  relation "customers" already exists
2026-11-25 04:54:07 [INFO] [salesdb] Command was: CREATE TABLE sales.customers (
2026-11-25 04:54:07 [INFO] [salesdb]     id integer NOT NULL,
2026-11-25 04:54:07 [INFO] [salesdb]     name text
2026-11-25 04:54:07 [INFO] [salesdb] );
2026-11-25 04:54:07 [ERROR] [salesdb] pg_restore: error: could not execute query: ERROR:  relation "orders" already exists
2026-11-25 04:54:07 [INFO] [salesdb] Command was: CREATE TABLE sales.orders (
2026-11-25 04:54:07 [INFO] [salesdb]     id integer NOT NULL,
2026-11-25 04:54:07 [INFO] [salesdb]     amount numeric,
2026-11-25 04:54:07 [INFO] [salesdb]     note text
2026-11-25 04:54:07 [INFO] [salesdb] );
2026-11-25 04:54:07 [ERROR] [salesdb] pg_restore: error: could not execute query: ERROR:  relation "orders_id_seq" already exists
2026-11-25 04:54:07 [INFO] [salesdb] Command was: ALTER TABLE sales.orders ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
2026-11-25 04:54:07 [INFO] [salesdb]     SEQUENCE NAME sales.orders_id_seq
2026-11-25 04:54:07 [INFO] [salesdb]     START WITH 1
2026-11-25 04:54:07 [INFO] [salesdb]     INCREMENT BY 1
2026-11-25 04:54:07 [INFO] [salesdb]     NO MINVALUE
2026-11-25 04:54:07 [INFO] [salesdb]     NO MAXVALUE
2026-11-25 04:54:07 [INFO] [salesdb]     CACHE 1
2026-11-25 04:54:08 [INFO] [salesdb] );
2026-11-25 04:54:08 [ERROR] [salesdb] pg_restore: error: COPY failed for table "customers": ERROR:  duplicate key value violates unique constraint "customers_pkey"
2026-11-25 04:54:08 [INFO] [salesdb] DETAIL:  Key (id)=(1) already exists.
2026-11-25 04:54:08 [INFO] [salesdb] CONTEXT:  COPY customers, line 1
2026-11-25 04:54:08 [ERROR] [salesdb] pg_restore: error: COPY failed for table "orders": ERROR:  duplicate key value violates unique constraint "orders_pkey"
2026-11-25 04:54:08 [INFO] [salesdb] DETAIL:  Key (id)=(1) already exists.
2026-11-25 04:54:08 [INFO] [salesdb] CONTEXT:  COPY orders, line 1
2026-11-25 04:54:08 [ERROR] [salesdb] pg_restore: error: could not execute query: ERROR:  multiple primary keys for table "customers" are not allowed
2026-11-25 04:54:08 [INFO] [salesdb] Command was: ALTER TABLE ONLY sales.customers
2026-11-25 04:54:08 [INFO] [salesdb]     ADD CONSTRAINT customers_pkey PRIMARY KEY (id);
2026-11-25 04:54:08 [ERROR] [salesdb] pg_restore: error: could not execute query: ERROR:  multiple primary keys for table "orders" are not allowed
2026-11-25 04:54:08 [INFO] [salesdb] Command was: ALTER TABLE ONLY sales.orders
2026-11-25 04:54:08 [INFO] [salesdb]     ADD CONSTRAINT orders_pkey PRIMARY KEY (id);
2026-11-25 04:54:08 [INFO] [salesdb] pg_restore: warning: errors ignored on restore: 9
2026-11-25 04:54:08 [ERROR] [salesdb] Restore failed (exit 1) after 0m01s
2026-11-25 04:54:08 [INFO] Summary:
2026-11-25 04:54:08 [INFO]   DATABASE                 STATUS    STAGE      SIZE     TIME     FILE
2026-11-25 04:54:08 [INFO]   hrdb_new                 OK        -          4.0K     0m00s    /backups/postgres/db1.example.internal_5432/hrdb_20261125_045405.dump
2026-11-25 04:54:08 [INFO]   salesdb                  FAIL(3)   restore    8.0K     0m01s    /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump
2026-11-25 04:54:08 [ERROR] Run finished with exit code 3 (stage: restore (salesdb))


------------------------------------------------------------------------------
6) --servers with one server down, psql backups, RESTORE N approval
------------------------------------------------------------------------------
$ pg_restore_wrapper.sh --servers /etc/pg_restore/servers.txt --from .../salesdb_20261125_045407.dump -d salesdb --clean --if-exists --no-owner --no-privileges --backup-first=psql -o /backups/restore-work (answer: RESTORE 1)
RESTORE 1
2026-11-25 04:54:08 [INFO] ===== pg_restore_wrapper.sh v1.0.0: 2 server(s) from /etc/pg_restore/servers.txt: db1.example.internal:5432, db3.example.internal:5432 =====
2026-11-25 04:54:08 [INFO] Using pg_restore (PostgreSQL) 17.12 (Debian 17.12-0+deb13u1) (/usr/bin/pg_restore)
2026-11-25 04:54:08 [INFO] Log file: /backups/restore-work/pg_restore_wrapper.log
2026-11-25 04:54:08 [INFO] Free space in /backups/restore-work: 123556 MB
2026-11-25 04:54:08 [INFO] File map (1):
2026-11-25 04:54:08 [INFO]   salesdb_20261125_045405.dump -> salesdb  (8.0K, custom)
2026-11-25 04:54:08 [INFO] Checksum OK: salesdb_20261125_045405.dump
2026-11-25 04:54:08 [INFO] [db1.example.internal:5432] Server 1/2: user=dba_admin databases=all
2026-11-25 04:54:08 [INFO] [db1.example.internal:5432] Connected: server_version_num=170012
2026-11-25 04:54:08 [INFO] [db3.example.internal:5432] Server 2/2: user=dba_admin databases=all
2026-11-25 04:54:08 [ERROR] [db3.example.internal:5432] Server not accepting connections at db3.example.internal:5432 (pg_isready)

RESTORE SUMMARY
  Targets    : 1 of 2 server(s) will be restored (/etc/pg_restore/servers.txt)
  Source     : /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump  (1 file(s), 8.0K)
  Server 1   : db1.example.internal:5432  user=dba_admin  databases=all
  Files      : salesdb_20261125_045405.dump -> salesdb  (exists, 3 table(s) will be overwritten)
  Server 2   : db3.example.internal:5432  user=dba_admin  databases=all
               (unreachable - will not be restored)
  Options    : --clean --if-exists --no-owner --no-privileges
  Checksums  : 1 OK
  Backup     : 3 table(s) psql copy -> public.<table>_bkp_20261125_0454

Type RESTORE 1 to continue, anything else cancels: 2026-11-25 04:54:08 [INFO] Answer: RESTORE 1
2026-11-25 04:54:08 [INFO] Approval accepted (RESTORE 1)
2026-11-25 04:54:08 [INFO] Starting pre-restore backups (psql): 3 table(s)
2026-11-25 04:54:08 [INFO] [db1.example.internal:5432/salesdb] Backing up public.regions with psql -> public.regions_bkp_20261125_0454
2026-11-25 04:54:08 [INFO] [db1.example.internal:5432/salesdb] psql copy OK: public.regions_bkp_20261125_0454 (3 rows)
2026-11-25 04:54:08 [INFO] [db1.example.internal:5432/salesdb] Backing up sales.customers with psql -> public.customers_bkp_20261125_0454
2026-11-25 04:54:08 [INFO] [db1.example.internal:5432/salesdb] psql copy OK: public.customers_bkp_20261125_0454 (40 rows)
2026-11-25 04:54:08 [INFO] [db1.example.internal:5432/salesdb] Backing up sales.orders with psql -> public.orders_bkp_20261125_0454
2026-11-25 04:54:08 [INFO] [db1.example.internal:5432/salesdb] psql copy OK: public.orders_bkp_20261125_0454 (500 rows)
2026-11-25 04:54:08 [INFO] Pre-restore backups finished OK (psql)
2026-11-25 04:54:08 [INFO] [db1.example.internal:5432/salesdb] Starting restore (custom) <- /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump
2026-11-25 04:54:08 [INFO] [db1.example.internal:5432/salesdb] Command: pg_restore -h db1.example.internal -p 5432 -U dba_admin -d salesdb --no-password --clean --if-exists --no-owner --no-privileges /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump
2026-11-25 04:54:08 [INFO] [db1.example.internal:5432/salesdb] Restore finished in 0m00s
2026-11-25 04:54:08 [INFO] Rollback commands (from the pre-restore backup):
# db1.example.internal:5432/salesdb public.regions  (psql copy -> public.regions_bkp_20261125_0454, 3 rows)
psql -h db1.example.internal -p 5432 -U dba_admin -d salesdb -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
TRUNCATE "public"."regions";
INSERT INTO "public"."regions" (id, name) OVERRIDING SYSTEM VALUE SELECT id, name FROM "public"."regions_bkp_20261125_0454";
COMMIT;
-- when no longer needed: DROP TABLE "public"."regions_bkp_20261125_0454";
SQL

# db1.example.internal:5432/salesdb sales.customers  (psql copy -> public.customers_bkp_20261125_0454, 40 rows)
psql -h db1.example.internal -p 5432 -U dba_admin -d salesdb -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
TRUNCATE "sales"."customers";
INSERT INTO "sales"."customers" (id, name) OVERRIDING SYSTEM VALUE SELECT id, name FROM "public"."customers_bkp_20261125_0454";
COMMIT;
-- when no longer needed: DROP TABLE "public"."customers_bkp_20261125_0454";
SQL

# db1.example.internal:5432/salesdb sales.orders  (psql copy -> public.orders_bkp_20261125_0454, 500 rows)
psql -h db1.example.internal -p 5432 -U dba_admin -d salesdb -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
TRUNCATE "sales"."orders";
INSERT INTO "sales"."orders" (id, amount, note) OVERRIDING SYSTEM VALUE SELECT id, amount, note FROM "public"."orders_bkp_20261125_0454";
COMMIT;
-- when no longer needed: DROP TABLE "public"."orders_bkp_20261125_0454";
SQL
2026-11-25 04:54:08 [INFO] Rollback commands saved (review, then run with bash): /backups/restore-work/rollback_20261125_045408.sh
2026-11-25 04:54:08 [INFO] Summary:
2026-11-25 04:54:08 [INFO]   SERVER/DATABASE                   STATUS    STAGE      SIZE     TIME     FILE
2026-11-25 04:54:08 [INFO]   db3.example.internal:5432         FAIL(2)   precheck   -        0m00s    -
2026-11-25 04:54:08 [INFO]   db1.example.internal:5432/salesdb OK        -          8.0K     0m00s    /backups/postgres/db1.example.internal_5432/salesdb_20261125_045405.dump
2026-11-25 04:54:08 [ERROR] Run finished with exit code 2 (stage: precheck (db3.example.internal:5432))
```
