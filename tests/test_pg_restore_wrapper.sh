#!/usr/bin/env bash
# shellcheck disable=SC2016  # bash -c '...' snippets get their values as $1, $2
#
# End-to-end tests for pg_restore_wrapper.sh against two throwaway PostgreSQL clusters.
#
# Dumps are made with the real pg_dump_wrapper.sh, so the folder layout, names and
# .sha256 files are exactly what the backup job writes. Restores run as a NON-superuser
# role with CREATEDB (like Aurora's rds_superuser master user).
# Prompts are answered through a real pseudo-terminal (util-linux `script`); the
# "no terminal" cases run under `setsid`, which has no controlling terminal.
#
# Usage:
#   PRW_SERVER_BIN=/usr/lib/postgresql/17/bin PRW_DUMP_WRAPPER=/path/pg_dump_wrapper.sh tests/test_pg_restore_wrapper.sh
# Settings (environment):
#   PRW_SERVER_BIN    dir with initdb/pg_ctl     (default: $PDW_SERVER_BIN, else dir of `initdb` in PATH)
#   PRW_CLIENT_BIN    dir with pg_restore/psql   (default: dir of `pg_restore` in PATH)
#   PRW_DUMP_WRAPPER  pg_dump_wrapper.sh         (default: next to the wrapper, else on PATH)
#   PRW_TEST_PORT     first cluster port         (default: 54339; +1 second cluster, +2 nothing listens)
#   PRW_KEEP          1 = keep the temp dir
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${PRW_WRAPPER:-$HERE/../pg_restore_wrapper.sh}"
SERVER_BIN="${PRW_SERVER_BIN:-${PDW_SERVER_BIN:-$(dirname "$(command -v initdb || echo /nonexistent/initdb)")}}"
CLIENT_BIN="${PRW_CLIENT_BIN:-$(dirname "$(command -v pg_restore || echo /nonexistent/pg_restore)")}"
PDW="${PRW_DUMP_WRAPPER:-}"
[[ -n "$PDW" ]] || { if [[ -r "$HERE/../pg_dump_wrapper.sh" ]]; then PDW="$HERE/../pg_dump_wrapper.sh"; else PDW="$(command -v pg_dump_wrapper.sh || true)"; fi; }
PORT="${PRW_TEST_PORT:-54339}"; PORT2=$((PORT + 1)); DOWN=$((PORT + 2))
SU="postgres"; SU_PW="prw_su_pw"; SU_PW2="prw_su_pw_two"
AR="aurora_admin"; AR_PW="prw_ar_pw"     # non-superuser with CREATEDB, like rds_superuser
H="127.0.0.1"

[[ -x "$SERVER_BIN/initdb" ]] || { echo "initdb not found; set PRW_SERVER_BIN" >&2; exit 2; }
[[ -x "$CLIENT_BIN/pg_restore" ]] || { echo "pg_restore not found; set PRW_CLIENT_BIN" >&2; exit 2; }
[[ -r "$PDW" ]] || { echo "pg_dump_wrapper.sh not found; set PRW_DUMP_WRAPPER" >&2; exit 2; }
command -v script >/dev/null && command -v setsid >/dev/null || { echo "needs util-linux script and setsid" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/prw-test.XXXXXX")"
cleanup() {
    for d in "$T/pg1" "$T/pg2"; do [[ -d "$d" ]] && "$SERVER_BIN/pg_ctl" -D "$d" -m fast -w stop >/dev/null 2>&1; done
    [[ -n "${HOOK_PID:-}" ]] && kill "$HOOK_PID" 2>/dev/null
    if [[ "${PRW_KEEP:-0}" == 1 ]]; then echo "kept $T"; else rm -rf -- "$T"; fi
}
trap cleanup EXIT
cd "$T" || exit 2

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | tail -n 30 | sed 's/^/       | /'; return 0; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d" "$OUT"; fi; }
section() { printf '\n== %s\n' "$1"; }
has()   { grep -qF -- "$1" <<<"$OUT"; }
hasnt() { ! grep -qF -- "$1" <<<"$OUT"; }
hasre() { grep -qE -- "$1" <<<"$OUT"; }

OUT=""; RC=0
run() {      # no terminal (setsid): output in $OUT, exit code in $RC
    OUT="$(setsid -w bash "$WRAPPER" "$@" 2>&1 </dev/null)"; RC=$?
}
tty_run() {  # tty_run "answers\n" args... : run on a pseudo-terminal, typing the answers
    local input="$1" cmd; shift
    cmd="$(printf '%q ' bash "$WRAPPER" "$@")"
    OUT="$(printf '%b' "$input" | timeout 300 script -qefc "$cmd" /dev/null 2>&1)"; RC=$?
    OUT="${OUT//$'\r'/}"
}
q()  { PGPASSFILE="$PGPASS" "$CLIENT_BIN/psql" -X -A -t -q -h "$H" -p "$1" -U "$SU" -d "$2" -c "$3" 2>&1; }   # q PORT DB SQL
export -f q; export PGPASS CLIENT_BIN H SU
bkp_count() { q "$PORT" "$1" "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind='r' AND c.relname LIKE '%\\_bkp\\_%'"; }

# ----------------------------------------------------------------------------
section "Start PostgreSQL ($("$SERVER_BIN/postgres" --version)) on ports $PORT and $PORT2"
start_cluster() {   # start_cluster DIR PORT PASSWORD
    printf '%s\n' "$3" >"$T/pw"
    "$SERVER_BIN/initdb" -D "$1" -U "$SU" --auth=scram-sha-256 --pwfile="$T/pw" >"$1.initdb.log" 2>&1 || { cat "$1.initdb.log"; exit 2; }
    "$SERVER_BIN/pg_ctl" -D "$1" -l "$1.log" -w -o "-p $2 -k $T -c listen_addresses=$H" start >/dev/null || { cat "$1.log"; exit 2; }
}
start_cluster "$T/pg1" "$PORT" "$SU_PW"
start_cluster "$T/pg2" "$PORT2" "$SU_PW2"
PGPASS="$T/pgpass"
printf '%s:%s:*:%s:%s\n%s:%s:*:%s:%s\n%s:%s:*:%s:%s\n%s:%s:*:%s:%s\n' \
    "$H" "$PORT" "$SU" "$SU_PW" "$H" "$PORT" "$AR" "$AR_PW" "$H" "$PORT2" "$SU" "$SU_PW2" "$H" "$DOWN" "$SU" "x" >"$PGPASS"
chmod 600 "$PGPASS"
q "$PORT" postgres "CREATE ROLE $AR LOGIN CREATEDB NOSUPERUSER PASSWORD '$AR_PW'" >/dev/null
for db in src hr plaindb locked; do q "$PORT" postgres "CREATE DATABASE $db" >/dev/null; done
q "$PORT" src "CREATE SCHEMA sales;
  CREATE TABLE sales.orders(id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, note text);
  INSERT INTO sales.orders(note) SELECT 'order ' || g FROM generate_series(1,100) g;
  CREATE TABLE sales.customers(id int PRIMARY KEY, name text); INSERT INTO sales.customers SELECT g, 'c' || g FROM generate_series(1,10) g;
  CREATE TABLE public.orders(id int); INSERT INTO public.orders VALUES (1),(2),(3);
  CREATE TABLE public.regions(id int PRIMARY KEY, name text); INSERT INTO public.regions SELECT g, 'r' || g FROM generate_series(1,5) g;" >/dev/null
q "$PORT" hr "CREATE SCHEMA hr; CREATE TABLE hr.staff(id int PRIMARY KEY); INSERT INTO hr.staff SELECT generate_series(1,20);" >/dev/null
q "$PORT" plaindb "CREATE TABLE items(id int); INSERT INTO items SELECT generate_series(1,7);" >/dev/null
q "$PORT" locked "REVOKE CREATE ON DATABASE locked FROM PUBLIC" >/dev/null
check "restore role is NOT a superuser (Aurora-like)" test "$(q "$PORT" postgres "SELECT rolsuper FROM pg_roles WHERE rolname='$AR'")" = f

D="$T/dumps/${H}_${PORT}"; P="$T/plain"
PDWC=(-h "$H" -p "$PORT" -U "$SU" --pgpassfile "$PGPASS" --min-free-mb 1 --table-sizes 0)
bash "$PDW" "${PDWC[@]}" -d src -o "$D" >/dev/null 2>&1
old="$(ls "$D"/src_*.dump)"; mv "$old" "$D/src_20200101_000000.dump"           # older dump (5 regions, no checksum)
q "$PORT" src "INSERT INTO public.regions VALUES (6, 'r6')" >/dev/null
sleep 1
bash "$PDW" "${PDWC[@]}" -d src --checksum -o "$D" >/dev/null 2>&1               # newest: 6 regions
bash "$PDW" "${PDWC[@]}" -d hr -F directory --checksum -o "$D" >/dev/null 2>&1
bash "$PDW" "${PDWC[@]}" -d plaindb -F plain -o "$P" >/dev/null 2>&1
bash "$PDW" "${PDWC[@]}" -d plaindb -F plain -Z 6 -o "$P/gz" >/dev/null 2>&1
check "test dumps made with pg_dump_wrapper (2 src, 1 hr dir, checksums)" \
    bash -c '[[ $(ls "$1"/src_*.dump | wc -l) -eq 2 && -d $(ls -d "$1"/hr_*.dir) && $(ls "$1"/*.sha256 | wc -l) -eq 2 ]]' _ "$D"
SRC_NEW=""; for f in "$D"/src_2*.dump; do [[ "$f" == *20200101* ]] || SRC_NEW="$f"; done
OUTD="$T/out"
C=(-h "$H" -p "$PORT" -U "$AR" --pgpassfile "$PGPASS" --min-free-mb 1 --pg-dump-wrapper "$PDW" -o "$OUTD" --no-owner)
C_OWNER=(-h "$H" -p "$PORT" -U "$AR" --pgpassfile "$PGPASS" --min-free-mb 1 -o "$OUTD")
MAPS=(--map 'src_*=t_src' --map 'hr_*=t_hr')

# ----------------------------------------------------------------------------
section "Options and validation"
run --help;    check "--help exits 0" test "$RC" -eq 0
run --version; check "--version prints 1.0.0" has "1.0.0"
run "${C[@]}"; check "missing --from -> exit 1" test "$RC" -eq 1
run "${C[@]}" --from "$SRC_NEW" --yes
check "single file without -d -> exit 2, nothing guessed" bash -c '[[ $1 -eq 2 ]] && grep -q "needs -d DB" <<<"$2"' _ "$RC" "$OUT"
run "${C[@]}" --from "$D" -d t_src --yes;                       check "-d with a folder -> exit 1" test "$RC" -eq 1
run "${C[@]}" --from "$D" "${MAPS[@]}" --backup-first --force;   check "--backup-first with --force -> exit 1" test "$RC" -eq 1
run "${C[@]}" --from "$D" "${MAPS[@]}" --backup-first=zip;       check "bad backup method -> exit 1" test "$RC" -eq 1
run "${C[@]}" --from "$D" --map 'src_*'; check "--map without =DB -> exit 1" test "$RC" -eq 1

run "${C[@]}" --from "$D" --map 'src_*=t_src' --create --yes
check "unmapped selected file -> exit 2 before anything starts" bash -c '[[ $1 -eq 2 ]] && grep -q "No --map for selected file: hr_" <<<"$2" && grep -q "Nothing was restored" <<<"$2"' _ "$RC" "$OUT"
check "unmapped refusal created nothing" test -z "$(q "$PORT" postgres "SELECT 1 FROM pg_database WHERE datname='t_src'")"

# ----------------------------------------------------------------------------
section "Dry run"
run "${C[@]}" --from "$D" "${MAPS[@]}" --create --clean --if-exists -j 2 --dry-run -o "$T/dry"
check "dry-run exits 0" test "$RC" -eq 0
check "dry-run shows RESTORE SUMMARY with both files" bash -c 'grep -q "RESTORE SUMMARY" <<<"$1" && grep -qE "src_2[0-9_]+\.dump +-> t_src +\(new, will be created\)" <<<"$1" && grep -qE "hr_[0-9_]+\.dir +-> t_hr" <<<"$1"' _ "$OUT"
check "dry-run skips the older dump of the same database" has "Skipping older dump (a newer file of the same dump is selected): $D/src_20200101_000000.dump"
check "dry-run prints the CREATE DATABASE and pg_restore commands" bash -c 'grep -q "CREATE DATABASE \\\\\"t_src\\\\\"\|CREATE\\\\ DATABASE" <<<"$1" && grep -qE "pg_restore -h 127.0.0.1 .* -d t_hr .*--jobs=2 --clean --if-exists" <<<"$1"' _ "$OUT"
check "dry-run says approval would be required" has "approval would be required: type $H"
check "dry-run wrote no files and created no database" bash -c '[[ ! -e "$1" ]] && [[ -z "$2" ]]' _ "$T/dry" "$(q "$PORT" postgres "SELECT 1 FROM pg_database WHERE datname='t_src'")"

# ----------------------------------------------------------------------------
section "Approval without a terminal"
run "${C[@]}" --from "$D" "${MAPS[@]}" --create
check "no terminal and no --yes -> exit 2, refuses" bash -c '[[ $1 -eq 2 ]] && grep -q "No terminal to approve the restore and --yes was not given" <<<"$2"' _ "$RC" "$OUT"
check "summary is still printed and logged before refusing" bash -c 'grep -q "RESTORE SUMMARY" <<<"$1" && grep -q "RESTORE SUMMARY" "$2"' _ "$OUT" "$OUTD/pg_restore_wrapper.log"
check "refusal created nothing" test -z "$(q "$PORT" postgres "SELECT 1 FROM pg_database WHERE datname='t_src'")"

# ----------------------------------------------------------------------------
section "Restore a dump-wrapper folder as a non-superuser (--create, --yes)"
run "${C_OWNER[@]}" --from "$SRC_NEW" -d t_owner --create --yes
check "non-superuser without --no-owner -> FAIL(3) with an Aurora hint" bash -c '[[ $1 -eq 3 ]] && grep -q "must be able to SET ROLE" <<<"$2" && grep -q "Re-run with --no-owner" <<<"$2"' _ "$RC" "$OUT"
run "${C[@]}" --from "$D" "${MAPS[@]}" --create --no-privileges -j 2 --yes
check "folder restore exits 0" test "$RC" -eq 0
check "checksums verified" bash -c 'grep -q "Checksum OK: src_2" <<<"$1" && grep -q "Checksum OK: hr_" <<<"$1"' _ "$OUT"
check "missing databases created, owned by the non-superuser" test "$(q "$PORT" postgres "SELECT string_agg(pg_get_userbyid(datdba), ',' ORDER BY datname) FROM pg_database WHERE datname IN ('t_src','t_hr')")" = "$AR,$AR"
check "newest src dump restored (6 regions, 100 orders)" test "$(q "$PORT" t_src "SELECT (SELECT count(*) FROM public.regions) || '/' || (SELECT count(*) FROM sales.orders)")" = "6/100"
check "directory-format hr dump restored (20 staff)" test "$(q "$PORT" t_hr "SELECT count(*) FROM hr.staff")" = 20
check "summary table has one OK row per file" bash -c 'grep -qE "DATABASE +STATUS +STAGE +SIZE +TIME +FILE" <<<"$1" && grep -qE "\] +t_src +OK " <<<"$1" && grep -qE "\] +t_hr +OK " <<<"$1"' _ "$OUT"
check "approval skipped is logged" has "Approval skipped (--yes)"
check "no backup needed for new databases" has "none needed (no existing tables will be overwritten)"

# ----------------------------------------------------------------------------
section "Existing tables: refuse without --backup-first / --force"
q "$PORT" t_src "UPDATE sales.orders SET note='CHANGED' WHERE id=1" >/dev/null
run "${C[@]}" --from "$SRC_NEW" -d t_src --clean --if-exists --yes
check "--yes with existing tables -> exit 2" bash -c '[[ $1 -eq 2 ]] && grep -q "4 existing table(s) would be overwritten" <<<"$2" && grep -q "never overwrites tables without a backup" <<<"$2"' _ "$RC" "$OUT"
check "warning lists the existing tables" has "public.orders, public.regions, sales.customers, sales.orders"
check "refusal prints the pg_dump_wrapper backup command" bash -c 'grep -qE "pg_dump_wrapper.sh -h 127.0.0.1 .* -d t_src .*-t \\\\\"sales\\\\\".\\\\\"orders\\\\\"|pg_dump_wrapper.sh .* -t .*sales.*orders" <<<"$1"' _ "$OUT"
check "data untouched after refusal" test "$(q "$PORT" t_src "SELECT note FROM sales.orders WHERE id=1")" = CHANGED
check "--clean set -> no 'already exists' warning" bash -c '! grep -q "clean is not set" <<<"$1"' _ "$OUT"
run "${C[@]}" --from "$SRC_NEW" -d t_src --yes
check "existing tables without --clean -> warns to add --clean --if-exists" bash -c '[[ $1 -eq 2 ]] && grep -q "\-\-clean is not set" <<<"$2" && grep -q "add --clean --if-exists" <<<"$2"' _ "$RC" "$OUT"

# ----------------------------------------------------------------------------
section "--backup-first=psql (copies into public, name collision gets _2)"
run "${C[@]}" --from "$SRC_NEW" -d t_src --clean --if-exists --backup-first=psql --yes
check "psql backup + restore exits 0" test "$RC" -eq 0
STAMP_RE='[0-9]{8}_[0-9]{4}'
check "copies named <table>_bkp_<YYYYMMDD_HHMM> in public" bash -c 'l="$(q "$1" t_src "SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE nspname='"'"'public'"'"' AND relname LIKE '"'"'%\_bkp\_%'"'"' ORDER BY 1")"; grep -qE "^customers_bkp_$2$" <<<"$l" && grep -qE "^regions_bkp_$2$" <<<"$l" && grep -qE "^orders_bkp_$2$" <<<"$l" && grep -qE "^orders_bkp_$2_2$" <<<"$l"' _ "$PORT" "$STAMP_RE"
check "two orders tables -> two copies, no collision" test "$(q "$PORT" t_src "SELECT count(*) FROM pg_class WHERE relkind = 'r' AND relname ~ '^orders_bkp_'")" -eq 2
BKO="$(q "$PORT" t_src "SELECT 'public.'||quote_ident(relname) FROM pg_class c WHERE relname ~ '^orders_bkp_' AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid=c.oid AND a.attname='note')")"
check "the sales.orders copy has the CHANGED row" test "$(q "$PORT" t_src "SELECT note FROM $BKO WHERE id=1")" = CHANGED
check "restore replaced the data" test "$(q "$PORT" t_src "SELECT note FROM sales.orders WHERE id=1")" = "order 1"
RB="$(grep -oE "Rollback commands saved \(review, then run with bash\): .*" <<<"$OUT" | sed 's/.*: //')"
check "rollback file written with TRUNCATE/INSERT SQL" bash -c '[[ -s "$1" ]] && grep -q "TRUNCATE \"sales\".\"orders\";" "$1" && grep -q "OVERRIDING SYSTEM VALUE" "$1"' _ "$RB"
PGPASSFILE="$PGPASS" bash "$RB" >/dev/null 2>&1
check "running the rollback file brings the old row back" test "$(q "$PORT" t_src "SELECT note FROM sales.orders WHERE id=1")" = CHANGED

printf 'backup_method=psql\nbackup_schema=bk_restore\n' >"$T/psql.conf"
run --config "$T/psql.conf" "${C[@]}" --from "$SRC_NEW" -d t_src --clean --if-exists --backup-first --yes
check "conf backup_method=psql + plain --backup-first, custom backup schema" bash -c '[[ $1 -eq 0 ]] && grep -q "Created backup schema bk_restore" <<<"$2" && grep -q "psql copy OK: bk_restore.orders_bkp_" <<<"$2"' _ "$RC" "$OUT"
printf 'backup_first=psql\nbackup_schema=bk_conf\n' >"$T/psql2.conf"
run --config "$T/psql2.conf" "${C[@]}" --from "$SRC_NEW" -d t_src --clean --if-exists --yes
check "conf backup_first=psql alone takes psql copies" bash -c '[[ $1 -eq 0 ]] && grep -q "psql copy OK: bk_conf.orders_bkp_" <<<"$2"' _ "$RC" "$OUT"

# ----------------------------------------------------------------------------
section "--backup-first=psql with a generated column"
q "$PORT" postgres "CREATE DATABASE gen OWNER $AR" >/dev/null
PGPASSFILE="$PGPASS" "$CLIENT_BIN/psql" -X -q -h "$H" -p "$PORT" -U "$AR" -d gen -c "CREATE TABLE public.prices(id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY, net numeric, gross numeric GENERATED ALWAYS AS (net * 1.18) STORED); INSERT INTO public.prices(net) VALUES (100), (200)" >/dev/null
bash "$PDW" "${PDWC[@]}" -d gen -O -o "$T/gen" >/dev/null 2>&1
GEN_DUMP="$(printf '%s\n' "$T"/gen/gen_*.dump | head -n1)"
q "$PORT" gen "UPDATE public.prices SET net = 999 WHERE id = 1" >/dev/null
run "${C[@]}" --from "$GEN_DUMP" -d gen --clean --if-exists --backup-first=psql --yes
check "psql copy works on a table with a generated column" bash -c '[[ $1 -eq 0 ]] && grep -q "psql copy OK: public.prices_bkp_.* (2 rows)" <<<"$2"' _ "$RC" "$OUT"
GEN_BK="$(q "$PORT" gen "SELECT relname FROM pg_class WHERE relkind = 'r' AND relname LIKE 'prices_bkp_%'")"
check "copy holds the old row with its generated value" test "$(q "$PORT" gen "SELECT net || '/' || gross FROM public.\"$GEN_BK\" WHERE id = 1")" = "999/1178.82"
RB="$(grep -oE "Rollback commands saved \(review, then run with bash\): .*" <<<"$OUT" | sed 's/.*: //')"
check "rollback lists only the non-generated columns" grep -q 'INSERT INTO "public"."prices" (id, net) OVERRIDING SYSTEM VALUE SELECT id, net FROM' "$RB"
PGPASSFILE="$PGPASS" bash "$RB" >/dev/null 2>&1
check "rollback on a generated-column table brings net=999 back" test "$(q "$PORT" gen "SELECT net || '/' || gross FROM public.prices WHERE id = 1")" = "999/1178.82"

section "--backup-first (dump, via pg_dump_wrapper.sh)"
q "$PORT" t_src "UPDATE sales.orders SET note='CHANGED2' WHERE id=2" >/dev/null
run "${C[@]}" --from "$SRC_NEW" -d t_src --clean --if-exists --backup-first --yes
check "dump backup + restore exits 0" test "$RC" -eq 0
BF="$(ls "$OUTD/pre_restore_backups/${H}_${PORT}"/t_src_*.dump 2>/dev/null | tail -n1)"
check "backup file written by pg_dump_wrapper with checksum" bash -c '[[ -s "$1" && -s "$1.sha256" ]]' _ "$BF"
check "backup file holds exactly the existing tables" bash -c '[[ $("$1"/pg_restore -l "$2" | grep -c " TABLE DATA ") -eq 4 ]]' _ "$CLIENT_BIN" "$BF"
check "backup has the pre-restore row" bash -c '"$1"/pg_restore -a -t orders -n sales -f - "$2" | grep -q CHANGED2' _ "$CLIENT_BIN" "$BF"
check "rollback command printed (restore the backup file)" bash -c 'grep -qE "pg_restore_wrapper.sh -h 127.0.0.1 -p [0-9]+ -U aurora_admin --from .*t_src_[0-9_]+\.dump -d t_src --clean --if-exists --force" <<<"$1"' _ "$OUT"

printf '#!/usr/bin/env bash\necho "[ERROR] simulated backup failure" >&2\nexit 3\n' >"$T/fake_pdw.sh"
q "$PORT" t_src "UPDATE sales.orders SET note='KEEP' WHERE id=3" >/dev/null
run "${C[@]}" --pg-dump-wrapper "$T/fake_pdw.sh" --from "$SRC_NEW" -d t_src --clean --if-exists --backup-first --yes
check "backup failure -> exit 5" test "$RC" -eq 5
check "summary shows FAIL(5) backup, restore SKIPPED" bash -c 'grep -qE "t_src +FAIL\(5\) +backup" <<<"$1" && grep -qE "t_src +SKIPPED" <<<"$1"' _ "$OUT"
check "no restore started after the failed backup" test "$(q "$PORT" t_src "SELECT note FROM sales.orders WHERE id=3")" = KEEP

# ----------------------------------------------------------------------------
section "Existing tables: interactive prompt (typed on a terminal)"
tty_run 'cancel\n' "${C[@]}" --from "$SRC_NEW" -d t_src --clean --if-exists
check "cancel -> exit 2, nothing restored" bash -c '[[ $1 -eq 2 ]] && grep -q "Back them up first? \[dump / psql / skip / cancel\]" <<<"$2" && grep -q "Cancelled at the existing-tables prompt" <<<"$2"' _ "$RC" "$OUT"
check "data untouched after cancel" test "$(q "$PORT" t_src "SELECT note FROM sales.orders WHERE id=3")" = KEEP
tty_run 'skip\noverwrite 4\n' "${C[@]}" --from "$SRC_NEW" -d t_src --clean --if-exists
check "skip + wrong confirmation -> exit 2" bash -c '[[ $1 -eq 2 ]] && grep -q "Type OVERWRITE 4 to restore WITHOUT a backup" <<<"$2" && grep -q "Not confirmed" <<<"$2"' _ "$RC" "$OUT"
before="$(bkp_count t_src)"
tty_run "skip\nOVERWRITE 4\n$H\n" "${C[@]}" --from "$SRC_NEW" -d t_src --clean --if-exists
check "skip + OVERWRITE 4 + host name -> restored, exit 0" bash -c '[[ $1 -eq 0 ]] && grep -q "Approval accepted (127.0.0.1)" <<<"$2" && grep -q "Backup     : NONE - OVERWRITE 4 confirmed" <<<"$2"' _ "$RC" "$OUT"
check "skip took no backup" test "$(bkp_count t_src)" = "$before"
check "data replaced" test "$(q "$PORT" t_src "SELECT note FROM sales.orders WHERE id=3")" = "order 3"
q "$PORT" t_src "UPDATE sales.orders SET note='P' WHERE id=4" >/dev/null
tty_run "psql\n$H\n" "${C[@]}" --from "$SRC_NEW" -d t_src --clean --if-exists
check "psql answer: backup, summary, host approval, restore" bash -c '[[ $1 -eq 0 ]] && grep -q "psql copy OK" <<<"$2" && grep -q "already backed up (psql)" <<<"$2"' _ "$RC" "$OUT"
check "psql answer added 4 copies" test "$(bkp_count t_src)" -eq $(( before + 4 ))
nb="$(ls "$OUTD/pre_restore_backups/${H}_${PORT}"/t_src_*.dump | wc -l)"
tty_run "dump\nwrong.host\n" "${C[@]}" --from "$SRC_NEW" -d t_src --clean --if-exists
check "dump answer + wrong host name -> exit 2, cancelled" bash -c '[[ $1 -eq 2 ]] && grep -q "Approval not given" <<<"$2" && grep -q "Cancelled - nothing was restored" <<<"$2"' _ "$RC" "$OUT"
check "dump answer took the backup before the approval" test "$(ls "$OUTD/pre_restore_backups/${H}_${PORT}"/t_src_*.dump | wc -l)" -eq $(( nb + 1 ))
tty_run "$H\n" "${C[@]}" --from "$D" --map 'src_*=t_new' --include 'src_*' --create
check "host-name approval on a terminal (no existing tables)" bash -c '[[ $1 -eq 0 ]] && grep -q "Type the target host name to continue (127.0.0.1)" <<<"$2"' _ "$RC" "$OUT"

# ----------------------------------------------------------------------------
section "One file fails, the others continue"
run "${C[@]}" --from "$D" --map 'src_*=t_src2' --map 'hr_*=locked' --create --yes
check "permission failure -> exit 3" test "$RC" -eq 3
check "locked: FAIL(3) restore; t_src2: OK" bash -c 'grep -qE "\] +locked +FAIL\(3\) +restore" <<<"$1" && grep -qE "\] +t_src2 +OK" <<<"$1"' _ "$OUT"
check "pg_restore error is in the log" grep -q "permission denied for database locked" "$OUTD/pg_restore_wrapper.log"
check "t_src2 restored despite the failure" test "$(q "$PORT" t_src2 "SELECT count(*) FROM sales.orders")" = 100

D2="$T/dumps_bad"; cp -r "$D" "$D2"; f="$(ls "$D2"/hr_*.dir/*.dat.gz 2>/dev/null | head -n1)"; [[ -n "$f" ]] || f="$(ls "$D2"/hr_*.dir/toc.dat)"; printf 'x' >>"$f"
run "${C[@]}" --from "$D2" --map 'src_*=t_src3' --map 'hr_*=t_hr3' --create --yes
check "checksum mismatch -> FAIL(4) checksum, other file OK, exit 4" bash -c '[[ $1 -eq 4 ]] && grep -qE "\] +t_hr3 +FAIL\(4\) +checksum" <<<"$2" && grep -qE "\] +t_src3 +OK" <<<"$2"' _ "$RC" "$OUT"
check "file with a bad checksum was not restored" test -z "$(q "$PORT" postgres "SELECT 1 FROM pg_database WHERE datname='t_hr3'")"

# ----------------------------------------------------------------------------
section "Plain .sql and .sql.gz (psql), --include pin, --map-file, -n"
run "${C[@]}" --from "$(ls "$P"/plaindb_*.sql)" -d t_plain --create --yes
check "plain .sql restored with psql" bash -c '[[ $1 -eq 0 ]] && [[ $2 -eq 7 ]]' _ "$RC" "$(q "$PORT" t_plain "SELECT count(*) FROM items")"
run "${C[@]}" --from "$(ls "$P"/gz/plaindb_*.sql.gz)" -d t_plaingz --create --yes
check "plain .sql.gz restored with gzip | psql" bash -c '[[ $1 -eq 0 ]] && [[ $2 -eq 7 ]]' _ "$RC" "$(q "$PORT" t_plaingz "SELECT count(*) FROM items")"
run "${C[@]}" --from "$D" --include 'src_2020*' --map 'src_*=t_old' --create --yes
check "--include pins the older dump (5 regions)" bash -c '[[ $1 -eq 0 ]] && [[ $2 -eq 5 ]] && grep -q "No checksum file for src_20200101_000000.dump" <<<"$3"' _ "$RC" "$(q "$PORT" t_old "SELECT count(*) FROM regions")" "$OUT"
printf '# file=db\nsrc_*=t_n\n' >"$T/map.txt"
q "$PORT" postgres "CREATE DATABASE t_n OWNER $AR" >/dev/null
PGPASSFILE="$PGPASS" "$CLIENT_BIN/psql" -X -q -h "$H" -p "$PORT" -U "$AR" -d t_n -c "CREATE SCHEMA sales" >/dev/null   # -n restores objects in the schema, not the schema itself (pg_restore)
run "${C[@]}" --from "$D" --exclude 'hr_*' --map-file "$T/map.txt" -n sales --yes
check "--map-file + --exclude + -n sales" bash -c '[[ $1 -eq 0 ]] && [[ $2 == "t|f" ]]' _ "$RC" "$(q "$PORT" t_n "SELECT (to_regclass('sales.orders') IS NOT NULL)::text || '|' || (to_regclass('public.regions') IS NOT NULL)::text" | sed 's/true/t/;s/false/f/;s/true/t/;s/false/f/')"

# ----------------------------------------------------------------------------
section "Many servers (--servers): one down, one with a database list"
SV="$T/servers.txt"
printf '# host,port,user,databases\n%s,%s,%s,all\n%s,%s,%s,all\n %s , %s , %s , srv_src \n' "$H" "$PORT" "$AR" "$H" "$DOWN" "$SU" "$H" "$PORT2" "$SU" >"$SV"
SC=(--pgpassfile "$PGPASS" --min-free-mb 1 --pg-dump-wrapper "$PDW" -o "$T/srv" --no-owner)
run "${SC[@]}" --servers "$SV" --from "$D" --map 'src_*=srv_src' --map 'hr_*=srv_hr' --create --yes
check "--servers with a down server -> exit 2" test "$RC" -eq 2
check "down server: FAIL(2) precheck row" bash -c 'grep -qE "127\.0\.0\.1:$2 +FAIL\(2\) +precheck" <<<"$1"' _ "$OUT" "$DOWN"
check "other servers restored; rows labelled host:port/db" bash -c 'grep -q "SERVER/DATABASE" <<<"$1" && grep -qE "127\.0\.0\.1:$2/srv_src +OK" <<<"$1" && grep -qE "127\.0\.0\.1:$2/srv_hr +OK" <<<"$1" && grep -qE "127\.0\.0\.1:$3/srv_src +OK" <<<"$1"' _ "$OUT" "$PORT" "$PORT2"
check "databases field limits what a server gets (no srv_hr on server 3)" bash -c '! grep -qE "127\.0\.0\.1:$2/srv_hr" <<<"$1" && [[ -z "$3" ]]' _ "$OUT" "$PORT2" "$(PGPASSFILE="$PGPASS" "$CLIENT_BIN/psql" -X -At -h "$H" -p "$PORT2" -U "$SU" -d postgres -c "SELECT 1 FROM pg_database WHERE datname='srv_hr'")"
check "one log, lines tagged with the server" grep -q "\[127.0.0.1:$PORT2/srv_src\]" "$T/srv/pg_restore_wrapper.log"
tty_run 'RESTORE 3\n' "${SC[@]}" --servers "$SV" --from "$D" --map 'src_*=srv_src' --map 'hr_*=srv_hr' --force
check "RESTORE 3 when only 2 servers can be restored -> cancelled" bash -c '[[ $1 -eq 2 ]] && grep -q "Type RESTORE 2 to continue" <<<"$2" && grep -q "Approval not given" <<<"$2"' _ "$RC" "$OUT"
tty_run 'RESTORE 2\n' "${SC[@]}" --servers "$SV" --from "$D" --map 'src_*=srv_src' --map 'hr_*=srv_hr' --clean --if-exists --force
check "RESTORE 2 accepted; --force overwrites; down server still FAIL" bash -c '[[ $1 -eq 2 ]] && grep -q "Approval accepted (RESTORE 2)" <<<"$2" && grep -q "NONE - --force" <<<"$2" && [[ $(grep -cE "/srv_(src|hr) +OK" <<<"$2") -eq 3 ]]' _ "$RC" "$OUT"
run "${SC[@]}" --servers "$SV" --from "$D" --map 'src_*=srv_src' -W
check "-W with --servers -> exit 1, points to .pgpass" bash -c '[[ $1 -eq 1 ]] && grep -q "\-W cannot be used with --servers" <<<"$2"' _ "$RC" "$OUT"
run "${SC[@]}" --servers "$SV" --from "$D" --map 'src_*=srv_src' -h "$H"
check "-h with --servers -> exit 1" test "$RC" -eq 1

# ----------------------------------------------------------------------------
section "Alerts (webhook; e-mail needs a local mailer and is not tested)"
HOOK_PORT=$((PORT + 3)); HOOK_LOG="$T/hook.log"
python3 - "$HOOK_PORT" "$HOOK_LOG" >/dev/null 2>&1 <<'PY' &
import http.server, sys
port, log = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        open(log, 'ab').write(body + b'\n'); self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
PY
HOOK_PID=$!; sleep 1
run --from "$D" --alert-webhook "http://127.0.0.1:$HOOK_PORT/hook" --alert-webhook-format json --alert-test -o "$T/alert"
check "--alert-test posts a TEST webhook" bash -c '[[ $1 -eq 0 ]] && grep -q "\"status\":\"TEST\"" "$2"' _ "$RC" "$HOOK_LOG"
run "${C[@]}" --from "$D" --map 'src_*=t_src' --map 'hr_*=t_hr' --alert-webhook "http://127.0.0.1:$HOOK_PORT/hook" --alert-webhook-format json
check "refused run sends a FAILED webhook with the stage" bash -c 'grep -q "\"status\":\"FAILED\"" "$1" && grep -q "\"failed_stage\":\"precheck\"" "$1"' _ "$HOOK_LOG"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
