#!/usr/bin/env bash
#
# pg_restore_wrapper.sh - careful, cron-friendly wrapper around PostgreSQL pg_restore
#
# Restores one dump (file or directory format) or every dump in a folder, into one
# server or many (--servers FILE). Nothing is guessed: each source file is mapped to
# its target database explicitly (-d for one file, --map / --map-file for a folder).
# Before anything changes it verifies .sha256 checksums, lists every existing table the
# restore would overwrite, offers a backup of those tables (pg_dump_wrapper.sh or a psql
# copy), prints a RESTORE SUMMARY and waits for a typed approval.
#
# Exit codes (for multi-file / multi-server runs: the highest code of any row):
#   0    success
#   1    usage / validation error
#   2    pre-check failure or refusal (cannot connect, unmapped file, missing database
#        without --create, approval not given, no terminal without --yes,
#        existing tables without --backup-first / --force)
#   3    restore failed (pg_restore / psql, or CREATE DATABASE)
#   4    checksum failed
#   5    pre-restore backup failed (no restore was started)
#   130  interrupted (INT/TERM)
#
# Passwords are NEVER accepted on the command line. Use ~/.pgpass, PGPASSFILE (or the
# pgpassfile= config key), the PGPASSWORD environment variable, or -W to prompt once.
#
# Aurora / RDS: no superuser-only commands are used. Databases are created with plain
# CREATE DATABASE (needs CREATEDB, which rds_superuser has); --role runs SET ROLE.

set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"

# ----------------------------------------------------------------------------
# Constants (behaviour you can change lives in the config file / options below)
# ----------------------------------------------------------------------------
readonly CR=$'\r'
readonly WINDOWS_UNAME_RE='^(MINGW|MSYS|CYGWIN)'
readonly WINDOWS_EXE_SUFFIX=".exe"
readonly CHECKSUM_BITS=256
readonly CHECKSUM_SUFFIX=".sha256"
readonly PG_ISREADY_TIMEOUT=10
readonly TTY_DEVICE="/dev/tty"
readonly FIELD_SEP=$'\x1f'
readonly DUMP_DATE_RE='^(.*)_([0-9]{8}_[0-9]{6})(\..*)?$'   # pg_dump_wrapper names: <stem>_YYYYmmdd_HHMMSS.<ext>
readonly BACKUP_STAMP_FORMAT='%Y%m%d_%H%M'                    # <table>_bkp_<YYYYMMDD_HHMM>
readonly BACKUP_NAME_TAG="_bkp_"
readonly PG_MAX_IDENT=63
readonly ARCHIVE_MAGIC="PGDMP"
readonly TAR_MAGIC="ustar"
readonly TAR_MAGIC_OFFSET=257
readonly DIR_FORMAT_TOC="toc.dat"
readonly PLAIN_EXT=".sql"
readonly PLAIN_GZ_EXT=".sql.gz"
readonly UNSUPPORTED_EXT_RE='\.sql\.(zst|lz4|bz2|xz)$'
readonly IGNORED_FILE_RE='\.(sha256|log|txt|md|conf)$'
readonly SERVERS_ALL_KEYWORD="all"
readonly SERVERS_LINE_FORMAT="host,port,user,databases"
readonly DEFAULT_LOG_NAME="pg_restore_wrapper.log"
readonly DEFAULT_BACKUP_SUBDIR="pre_restore_backups"
readonly ROLLBACK_FILE_PREFIX="rollback_"
readonly ROLLBACK_FILE_EXT=".sh"
readonly DUMP_WRAPPER_NAME="pg_dump_wrapper.sh"
readonly DUMP_WRAPPER_DONE_RE='Backup completed successfully: (.*)$'
readonly APPROVE_SERVERS_WORD="RESTORE"
readonly APPROVE_OVERWRITE_WORD="OVERWRITE"
readonly ALERT_LOG_LINES=20
readonly PLAIN_OWNER_LINE_RE='^ALTER [A-Z ]+ .+ OWNER TO .+;$'          # dropped from plain dumps with --no-owner
readonly PLAIN_PRIV_LINE_RE='^(GRANT|REVOKE) .+;$'                       # dropped from plain dumps with --no-privileges
readonly OWNER_ERROR_RE='must be able to SET ROLE|must be member of role|must be owner of'   # Aurora/RDS: login is not a superuser
IS_WINDOWS=0
_uname="$(uname -s 2>/dev/null || true)"
[[ "${_uname//$CR/}" =~ $WINDOWS_UNAME_RE ]] && IS_WINDOWS=1
readonly IS_WINDOWS
unset _uname

# ----------------------------------------------------------------------------
# Defaults (lowest precedence: defaults < config file < command line)
# ----------------------------------------------------------------------------
DB_HOST="${PGHOST:-localhost}"
DB_PORT="${PGPORT:-5432}"
DB_USER="${PGUSER:-${USER:-postgres}}"
PGPASSFILE_OPT=""
PROMPT_PASSWORD=0
MAINTENANCE_DB="postgres"
SERVERS_FILE=""
CLI_HOST_PORT_OPT=""
CONF_HOST_PORT=0
FROM=""
TARGET_DB=""
MAPS=()
MAP_FILE=""
INCLUDES=()
EXCLUDES=()
STOP_ON_ERROR=0
JOBS=1
CLEAN=0
IF_EXISTS=0
CREATE=0
SCHEMA_ONLY=0
DATA_ONLY=0
INCLUDE_SCHEMAS=()
INCLUDE_TABLES=()
NO_OWNER=0
NO_PRIVILEGES=0
ROLE=""
EXIT_ON_ERROR=0
CHECKSUM=1
BACKUP_FIRST=0
BACKUP_METHOD="dump"
BACKUP_SCHEMA="public"
BACKUP_DIR=""
PG_DUMP_WRAPPER=""
FORCE=0
ASSUME_YES=0
OUTPUT_DIR="."
LOG_FILE=""
MIN_FREE_MB=1024
DRY_RUN=0
SKIP_PRECHECK=0
VERBOSE=0
PG_BIN=""
CONFIG_FILE=""
EXTRA_ARGS=()
ALERT_EMAILS=()
ALERT_WEBHOOKS=()
ALERT_ON="failure"
ALERT_WEBHOOK_FORMAT="slack"
ALERT_FROM=""
ALERT_TEST=0

# runtime state
MULTI=0                                  # 1 with --servers
SRV_HOSTS=(); SRV_PORTS=(); SRV_USERS=(); SRV_DBS=()
SRV_OK=()                                # 1 = reachable and planned
SERVER_LABEL=""
DB_NAME=""
BASE_USER=""
SRC_PATHS=(); SRC_NAMES=(); SRC_FORMATS=(); SRC_DBS=(); SRC_SIZES=(); SRC_SUMS=()
SKIPPED_OLDER=()
declare -A SRC_TABLES=()                 # src index -> "schema<FS>table" lines
U_SRV=(); U_SRC=(); U_DB=(); U_STATE=(); U_OVERLAP=(); U_PRE_RC=(); U_PRE_STAGE=(); U_PRE_MSG=()
declare -A BK_NEED=()                    # "srv|db" -> "schema<FS>table" lines (unique)
BK_KEYS=()                               # insertion order of BK_NEED keys
BK_ROWS=()                               # "srv|db|method|schema<FS>table|target|rows"; psql target = "schema<FS>table"
declare -A BK_COLS=()                    # BK_ROWS index -> quoted column list (psql copies; generated columns left out)
declare -A BK_USED=()
declare -A CREATED=()
BACKUP_STATE="none"                      # none | planned | done | skipped | forced
CHOSEN_METHOD=""
RUN_STAMP=""
RESULTS=()                               # "label|rc|stage|size|duration|file"
RUN_START=$SECONDS
RUN_START_TS=""
STAGE="init"
MAIN_STARTED=0
CANCELLED=0
CHILD_PID=""
CUR_UNIT=-1
WORST=0
FIRST_FAIL=""
ROLLBACK_FILE=""
SRV_ERR=""

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log() {
    local level="$1"; shift
    local tag="${SERVER_LABEL}${DB_NAME:+${SERVER_LABEL:+/}$DB_NAME}" line
    line="$(_ts) [$level]${tag:+ [$tag]} $*"
    printf '%s\n' "$line" >&2
    if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; fi
}
log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "$VERBOSE" -eq 1 ]] && _log DEBUG "$@"; return 0; }

log_block() {   # raw block on screen; timestamped copy in the log
    local l
    while IFS= read -r l; do
        printf '%s\n' "$l" >&2
        if [[ -n "$LOG_FILE" && "$DRY_RUN" -eq 0 ]]; then printf '%s [INFO] %s\n' "$(_ts)" "$l" >>"$LOG_FILE" 2>/dev/null || true; fi
    done
}

die() { local code="$1"; shift; log_error "$@"; exit "$code"; }

# ----------------------------------------------------------------------------
# Usage
# ----------------------------------------------------------------------------
usage() {
    cat <<USAGE
$SCRIPT_NAME v$SCRIPT_VERSION - wrapper around pg_restore

Usage: $SCRIPT_NAME --from FILE -d DB [options] [-- extra pg_restore args]
       $SCRIPT_NAME --from DIR (--map FILE=DB ... | --map-file F) [options]
       $SCRIPT_NAME --from FILE|DIR ... --servers FILE [options]

Connection:
  -h, --host HOST              Server host or socket dir          (default: \$PGHOST or localhost)
  -p, --port PORT              Server port                        (default: \$PGPORT or 5432)
  -U, --user USER              Database user                      (default: \$PGUSER or \$USER)
  -W, --password               Prompt once for the password at the start (needs a terminal)
      --pgpassfile FILE        Use this .pgpass file (sets PGPASSFILE)
      --maintenance-db DB      Database used to list and create databases (default: postgres)

Many servers (one after another, one summary):
      --servers FILE           One target per line: $SERVERS_LINE_FORMAT
                               (databases = $SERVERS_ALL_KEYWORD or a comma list of target
                               databases; empty user = -U). Every selected dump is
                               restored to each server. -h/-p/-W are not allowed;
                               passwords come from .pgpass (one line per host:port).

Source and mapping (nothing is guessed from file names):
      --from FILE|DIR          A dump file / directory-format dump, or a folder of dumps
                               (scanned one level deep; .sha256 and logs are ignored)
  -d, --dbname DB              Target database for a single --from FILE
      --map FILE=DB            Folder: restore files matching FILE (a name or shell glob,
                               e.g. 'salesdb_*') into DB. Repeatable / comma list.
                               First matching --map wins
      --map-file F             One FILE=DB line per mapping (# comments allowed)
      --include PATTERN        Only files whose names match this glob     [repeatable]
      --exclude PATTERN        Skip files whose names match this glob     [repeatable]
                               Several dates of the same dump: the newest is used and
                               the older ones are logged as skipped (--include can pin one).
                               A selected file with no mapping stops the run (exit 2).
      --stop-on-error          Stop at the first failed restore (default: continue)

Restore options:
  -j, --jobs N                 Parallel restore jobs (custom/directory dumps)
  -c, --clean                  Drop objects before recreating them
      --if-exists              Use DROP ... IF EXISTS (requires --clean)
  -C, --create                 Create the target database only if it does not exist
  -s, --schema-only            Restore only definitions
  -a, --data-only              Restore only data
  -n, --schema NAME            Restore only this schema                   [repeatable]
  -t, --table NAME             Restore only this table                    [repeatable]
  -O, --no-owner               Skip ownership commands
  -x, --no-privileges          Skip GRANT/REVOKE
      --role ROLE              SET ROLE before restoring (and before psql backups / CREATE DATABASE)
  -e, --exit-on-error          Stop pg_restore at its first error (default: pg_restore
                               continues and the file is marked FAIL(3) if any error happened)
      --no-checksum            Do not verify <dump>$CHECKSUM_SUFFIX files (default: verify when present)
  Plain .sql / .sql.gz dumps are restored with psql -v ON_ERROR_STOP=1. For them -O drops
  "ALTER ... OWNER TO" lines and -x drops GRANT/REVOKE lines; -j, -c, -n, -t, -s, -a do not apply.

Existing tables (tables in the dump that already exist in the target database):
      --backup-first[=METHOD]  Back them up before restoring. METHOD: dump (default) =
                               $DUMP_WRAPPER_NAME, one file per database; psql = copy each
                               table to BACKUP_SCHEMA.<table>${BACKUP_NAME_TAG}<YYYYMMDD_HHMM>
                               (CREATE TABLE ... (LIKE ... INCLUDING ALL) + INSERT ... SELECT).
                               Any backup failure: no restore starts (exit 5)
      --backup-schema NAME     Schema for psql copies                   (default: public)
      --backup-dir DIR         Folder for dump backups (default: OUTPUT_DIR/$DEFAULT_BACKUP_SUBDIR)
      --pg-dump-wrapper FILE   Path to $DUMP_WRAPPER_NAME (default: next to this script, then PATH)
      --force                  Overwrite existing tables without a backup
  Without --backup-first / --force you are warned and asked: dump / psql / skip / cancel.
  skip needs '$APPROVE_OVERWRITE_WORD N'. With --yes or no terminal the run refuses (exit 2).

Approval:
      --yes                    Skip the typed approval (the RESTORE SUMMARY is still logged).
                               Without --yes the run needs a terminal: type the target host
                               name, or '$APPROVE_SERVERS_WORD N' with --servers (N = servers restored to)

Files:
  -o, --output-dir DIR         Folder for the log, rollback file and dump backups (default: .)
  -l, --log-file FILE          Log file (default: OUTPUT_DIR/$DEFAULT_LOG_NAME)
      --min-free-mb N          Warn if free space in OUTPUT_DIR is below N MB (default: 1024)

Alerts:
      --alert-email ADDR       Mail the run report to ADDR (mail/mailx/sendmail) [repeatable]
      --alert-webhook URL      POST the run report via curl                     [repeatable]
      --alert-webhook-format F slack | json                       (default: slack)
      --alert-on WHEN          failure | always                    (default: failure)
      --alert-from ADDR        From address for e-mail alerts
      --alert-test             Send a test alert and exit

Behaviour:
      --config FILE            Load key=value settings (CLI arguments override them)
      --dry-run                Show the plan, summary and exact commands; change nothing
      --skip-precheck          Skip pg_isready and the free-space check
      --pg-bin DIR             Directory containing pg_restore/psql/pg_isready
  -v, --verbose                Debug logging + pass --verbose to pg_restore
      --help                   Show this help
      --version                Show wrapper version
  --                           Everything after -- is passed to pg_restore verbatim

Exit codes: 0 ok, 1 usage, 2 pre-check/refused, 3 restore, 4 checksum, 5 backup, 130 interrupted
(multi-file / multi-server runs exit with the highest code of any row)
USAGE
}

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }
add_list() {
    local -n _arr="$1"; local _item; local -a _parts
    IFS=',' read -r -a _parts <<<"$2"
    for _item in "${_parts[@]}"; do
        _item="$(trim "$_item")"
        [[ -n "$_item" ]] && _arr+=("$_item")
    done
    return 0
}
is_true() { case "${1,,}" in 1|y|yes|true|on) return 0 ;; *) return 1 ;; esac; }
strip_cr() { local -n _sc="$1"; _sc="${_sc//$CR/}"; }
need_arg() { [[ "$2" -ge 2 ]] || die 1 "Option $1 requires a value (see --help)"; }
fmt_duration() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }
quote_ident() { local s="${1//\"/\"\"}"; printf '"%s"' "$s"; }
quote_literal() { local s="${1//\'/\'\'}"; printf "'%s'" "$s"; }
qname() { printf '%s.%s' "$(quote_ident "$1")" "$(quote_ident "$2")"; }

bin() {
    local p="$1"
    [[ -n "$PG_BIN" ]] && p="${PG_BIN%/}/$1"
    if (( IS_WINDOWS )) && [[ "$p" == */* && ! -e "$p" && -e "$p$WINDOWS_EXE_SUFFIX" ]]; then p+="$WINDOWS_EXE_SUFFIX"; fi
    printf '%s' "$p"
}

to_unix_path() {
    local p="$1"
    if (( !IS_WINDOWS )) || [[ "$p" != *\\* && ! "$p" =~ ^[A-Za-z]: ]]; then printf '%s' "$p"; return 0; fi
    if command -v cygpath >/dev/null 2>&1; then p="$(cygpath -u "$p")"; strip_cr p
    else p="${p//\\//}"; [[ "$p" =~ ^([A-Za-z]):/?(.*)$ ]] && p="/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]}"; fi
    printf '%s' "$p"
}
native_path() {
    local p="$1"
    (( IS_WINDOWS )) || { printf '%s' "$p"; return 0; }
    if command -v cygpath >/dev/null 2>&1; then p="$(cygpath -m "$p")"; strip_cr p
    elif [[ "$p" =~ ^/([A-Za-z])(/.*)?$ ]]; then p="${BASH_REMATCH[1]^^}:${BASH_REMATCH[2]:-/}"; fi
    printf '%s' "$p"
}

free_kb_of() {
    local out; out="$(df -Pk -- "$1" 2>/dev/null)" || true; strip_cr out
    awk 'NR==2 { for (i = NF; i > 1; i--) if ($i ~ /^[0-9]+%$/) { print $(i-1); exit } }' <<<"$out"
}
host_name() { local h; h="$(hostname 2>/dev/null)" || h=""; strip_cr h; printf '%s' "${h:-unknown}"; }
size_of() { local s; s="$(du -sh -- "$1" 2>/dev/null | cut -f1)" || s="-"; printf '%s' "${s:--}"; }
redact_url() { if [[ "$1" =~ ^([a-zA-Z]+://[^/]+) ]]; then printf '%s/...' "${BASH_REMATCH[1]}"; else printf '<webhook>'; fi; }
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}
print_cmd() { local out="" a; for a in "$@"; do out+="$(printf '%q' "$a") "; done; printf '%s\n' "${out% }"; }

sha256_check() {   # sha256_check <sumfile>  (run inside the sum file's folder)
    if command -v sha256sum >/dev/null 2>&1; then sha256sum -c --quiet -- "$1"
    elif command -v shasum >/dev/null 2>&1; then shasum -a "$CHECKSUM_BITS" -c --quiet -- "$1"
    else echo "Neither sha256sum nor shasum is installed"; return 1; fi
}

# Read one answer from the terminal. Returns 1 if there is no terminal.
tty_ask() {   # tty_ask <prompt> <var>
    local -n _ans="$2"; local fd
    _ans=""
    { exec {fd}<>"$TTY_DEVICE"; } 2>/dev/null || return 1
    printf '%s' "$1" >&"$fd"
    IFS= read -r -u "$fd" _ans || true
    exec {fd}>&-
    _ans="$(trim "${_ans%"$CR"}")"
    _log INFO "Answer: ${_ans:-<empty>}"
    return 0
}
have_tty() { local fd; { exec {fd}<>"$TTY_DEVICE"; } 2>/dev/null || return 1; exec {fd}>&-; return 0; }

# ----------------------------------------------------------------------------
# Config file: key=value, '#' comments, optional quotes. Never sourced.
# ----------------------------------------------------------------------------
load_config() {
    local file line key val lineno=0
    file="$(to_unix_path "$1")"
    [[ -r "$file" ]] || die 1 "Config file not readable: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1)); line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_-]*)[[:space:]]*=[[:space:]]*(.*)$ ]] \
            || die 1 "Config $file:$lineno: invalid line (expected key=value)"
        key="${BASH_REMATCH[1],,}"; key="${key//-/_}"; val="${BASH_REMATCH[2]}"
        if [[ "$val" =~ ^\"([^\"]*)\" || "$val" =~ ^\'([^\']*)\' ]]; then val="${BASH_REMATCH[1]}"
        else
            [[ "$val" =~ ^(.*[^[:space:]])?[[:space:]]+#.*$ ]] && val="${BASH_REMATCH[1]}"
            val="${val%"${val##*[![:space:]]}"}"
        fi
        case "$key" in
            host)               DB_HOST="$val"; CONF_HOST_PORT=1 ;;
            port)               DB_PORT="$val"; CONF_HOST_PORT=1 ;;
            user|username)      DB_USER="$val" ;;
            pgpassfile)         PGPASSFILE_OPT="$val" ;;
            maintenance_db)     MAINTENANCE_DB="$val" ;;
            servers_file|servers) SERVERS_FILE="$val" ;;
            from)               FROM="$val" ;;
            dbname|database)    TARGET_DB="$val" ;;
            map)                MAPS=(); add_list MAPS "$val" ;;
            map_file)           MAP_FILE="$val" ;;
            include)            INCLUDES=(); add_list INCLUDES "$val" ;;
            exclude)            EXCLUDES=(); add_list EXCLUDES "$val" ;;
            stop_on_error)      is_true "$val" && STOP_ON_ERROR=1 || STOP_ON_ERROR=0 ;;
            jobs)               JOBS="$val" ;;
            clean)              is_true "$val" && CLEAN=1 || CLEAN=0 ;;
            if_exists)          is_true "$val" && IF_EXISTS=1 || IF_EXISTS=0 ;;
            create)             is_true "$val" && CREATE=1 || CREATE=0 ;;
            schema_only)        is_true "$val" && SCHEMA_ONLY=1 || SCHEMA_ONLY=0 ;;
            data_only)          is_true "$val" && DATA_ONLY=1 || DATA_ONLY=0 ;;
            schemas|schema)     INCLUDE_SCHEMAS=(); add_list INCLUDE_SCHEMAS "$val" ;;
            tables|table)       INCLUDE_TABLES=(); add_list INCLUDE_TABLES "$val" ;;
            no_owner)           is_true "$val" && NO_OWNER=1 || NO_OWNER=0 ;;
            no_privileges)      is_true "$val" && NO_PRIVILEGES=1 || NO_PRIVILEGES=0 ;;
            role)               ROLE="$val" ;;
            exit_on_error)      is_true "$val" && EXIT_ON_ERROR=1 || EXIT_ON_ERROR=0 ;;
            checksum)           is_true "$val" && CHECKSUM=1 || CHECKSUM=0 ;;
            backup_first)       case "${val,,}" in dump|psql) BACKUP_FIRST=1; BACKUP_METHOD="${val,,}" ;; *) is_true "$val" && BACKUP_FIRST=1 || BACKUP_FIRST=0 ;; esac ;;
            backup_method)      BACKUP_METHOD="$val" ;;
            backup_schema)      BACKUP_SCHEMA="$val" ;;
            backup_dir)         BACKUP_DIR="$val" ;;
            pg_dump_wrapper)    PG_DUMP_WRAPPER="$val" ;;
            force)              is_true "$val" && FORCE=1 || FORCE=0 ;;
            assume_yes|yes)     is_true "$val" && ASSUME_YES=1 || ASSUME_YES=0 ;;
            output_dir)         OUTPUT_DIR="$val" ;;
            log_file)           LOG_FILE="$val" ;;
            min_free_mb)        MIN_FREE_MB="$val" ;;
            verbose)            is_true "$val" && VERBOSE=1 || VERBOSE=0 ;;
            pg_bin)             PG_BIN="$val" ;;
            alert_email|alert_emails) ALERT_EMAILS=(); add_list ALERT_EMAILS "$val" ;;
            alert_webhook|alert_webhooks) ALERT_WEBHOOKS=(); add_list ALERT_WEBHOOKS "$val" ;;
            alert_webhook_format) ALERT_WEBHOOK_FORMAT="$val" ;;
            alert_on)           ALERT_ON="$val" ;;
            alert_from)         ALERT_FROM="$val" ;;
            password)           die 1 "Config $file:$lineno: 'password' is not supported; use ~/.pgpass or pgpassfile=" ;;
            *)                  die 1 "Config $file:$lineno: unknown key '$key'" ;;
        esac
    done <"$file"
}

# ----------------------------------------------------------------------------
# Arguments ("-x val", "--opt val", "--opt=val")
# ----------------------------------------------------------------------------
parse_args() {
    local i
    for (( i = 1; i <= $#; i++ )); do
        case "${!i}" in
            --config) (( i < $# )) || die 1 "Option --config requires a value"; i=$((i + 1)); CONFIG_FILE="${!i}" ;;
            --config=*) CONFIG_FILE="${!i#--config=}" ;;
            --) break ;;
        esac
    done
    [[ -n "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE"

    local -a args=()
    while (( $# )); do
        [[ "$1" == -- ]] && { args+=("$@"); break; }
        if [[ "$1" == --*=* && "$1" != --backup-first=* ]]; then args+=("${1%%=*}" "${1#*=}"); else args+=("$1"); fi
        shift
    done
    set -- "${args[@]+"${args[@]}"}"

    local cli_maps=0 cli_inc=0 cli_exc=0 cli_n=0 cli_t=0 cli_mail=0 cli_hook=0
    while (( $# )); do
        local opt="$1"
        case "$opt" in
            -h|--host)          need_arg "$opt" $#; DB_HOST="$2"; CLI_HOST_PORT_OPT="$opt"; shift 2 ;;
            -p|--port)          need_arg "$opt" $#; DB_PORT="$2"; CLI_HOST_PORT_OPT="$opt"; shift 2 ;;
            -U|--user|--username) need_arg "$opt" $#; DB_USER="$2"; shift 2 ;;
            -W|--password)      PROMPT_PASSWORD=1; shift ;;
            --pgpassfile)       need_arg "$opt" $#; PGPASSFILE_OPT="$2"; shift 2 ;;
            --maintenance-db)   need_arg "$opt" $#; MAINTENANCE_DB="$2"; shift 2 ;;
            --servers)          need_arg "$opt" $#; SERVERS_FILE="$2"; shift 2 ;;
            --from)             need_arg "$opt" $#; FROM="$2"; shift 2 ;;
            -d|--dbname)        need_arg "$opt" $#; TARGET_DB="$2"; shift 2 ;;
            --map)              need_arg "$opt" $#; (( cli_maps++ )) || MAPS=(); add_list MAPS "$2"; shift 2 ;;
            --map-file)         need_arg "$opt" $#; MAP_FILE="$2"; shift 2 ;;
            --include)          need_arg "$opt" $#; (( cli_inc++ )) || INCLUDES=(); add_list INCLUDES "$2"; shift 2 ;;
            --exclude)          need_arg "$opt" $#; (( cli_exc++ )) || EXCLUDES=(); add_list EXCLUDES "$2"; shift 2 ;;
            --stop-on-error)    STOP_ON_ERROR=1; shift ;;
            -j|--jobs)          need_arg "$opt" $#; JOBS="$2"; shift 2 ;;
            -c|--clean)         CLEAN=1; shift ;;
            --if-exists)        IF_EXISTS=1; shift ;;
            -C|--create)        CREATE=1; shift ;;
            -s|--schema-only)   SCHEMA_ONLY=1; shift ;;
            -a|--data-only)     DATA_ONLY=1; shift ;;
            -n|--schema)        need_arg "$opt" $#; (( cli_n++ )) || INCLUDE_SCHEMAS=(); add_list INCLUDE_SCHEMAS "$2"; shift 2 ;;
            -t|--table)         need_arg "$opt" $#; (( cli_t++ )) || INCLUDE_TABLES=(); add_list INCLUDE_TABLES "$2"; shift 2 ;;
            -O|--no-owner)      NO_OWNER=1; shift ;;
            -x|--no-privileges) NO_PRIVILEGES=1; shift ;;
            --role)             need_arg "$opt" $#; ROLE="$2"; shift 2 ;;
            -e|--exit-on-error) EXIT_ON_ERROR=1; shift ;;
            --no-checksum)      CHECKSUM=0; shift ;;
            --backup-first)     BACKUP_FIRST=1; shift ;;
            --backup-first=*)   BACKUP_FIRST=1; BACKUP_METHOD="${opt#--backup-first=}"; shift ;;
            --backup-schema)    need_arg "$opt" $#; BACKUP_SCHEMA="$2"; shift 2 ;;
            --backup-dir)       need_arg "$opt" $#; BACKUP_DIR="$2"; shift 2 ;;
            --pg-dump-wrapper)  need_arg "$opt" $#; PG_DUMP_WRAPPER="$2"; shift 2 ;;
            --force)            FORCE=1; shift ;;
            --yes|-y)           ASSUME_YES=1; shift ;;
            -o|--output-dir)    need_arg "$opt" $#; OUTPUT_DIR="$2"; shift 2 ;;
            -l|--log-file)      need_arg "$opt" $#; LOG_FILE="$2"; shift 2 ;;
            --min-free-mb)      need_arg "$opt" $#; MIN_FREE_MB="$2"; shift 2 ;;
            --alert-email)      need_arg "$opt" $#; (( cli_mail++ )) || ALERT_EMAILS=(); add_list ALERT_EMAILS "$2"; shift 2 ;;
            --alert-webhook)    need_arg "$opt" $#; (( cli_hook++ )) || ALERT_WEBHOOKS=(); add_list ALERT_WEBHOOKS "$2"; shift 2 ;;
            --alert-webhook-format) need_arg "$opt" $#; ALERT_WEBHOOK_FORMAT="$2"; shift 2 ;;
            --alert-on)         need_arg "$opt" $#; ALERT_ON="$2"; shift 2 ;;
            --alert-from)       need_arg "$opt" $#; ALERT_FROM="$2"; shift 2 ;;
            --alert-test)       ALERT_TEST=1; shift ;;
            --config)           shift 2 ;;
            --dry-run)          DRY_RUN=1; shift ;;
            --skip-precheck)    SKIP_PRECHECK=1; shift ;;
            --pg-bin)           need_arg "$opt" $#; PG_BIN="$2"; shift 2 ;;
            -v|--verbose)       VERBOSE=1; shift ;;
            --help|-\?)         usage; exit 0 ;;
            --version)          echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            --)                 shift; EXTRA_ARGS=("$@"); break ;;
            -*)                 die 1 "Unknown option: $opt (see --help)" ;;
            *)                  die 1 "Unexpected argument: $opt (use --from for the dump; see --help)" ;;
        esac
    done
    return 0
}

# ----------------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------------
validate_alerts() {
    case "${ALERT_ON,,}" in failure|always) ALERT_ON="${ALERT_ON,,}" ;; *) die 1 "--alert-on must be 'failure' or 'always'" ;; esac
    case "${ALERT_WEBHOOK_FORMAT,,}" in slack|json) ALERT_WEBHOOK_FORMAT="${ALERT_WEBHOOK_FORMAT,,}" ;; *) die 1 "--alert-webhook-format must be 'slack' or 'json'" ;; esac
    local a
    for a in "${ALERT_EMAILS[@]}"; do
        [[ "$a" =~ ^[^[:space:]@\;\|\&\$\`]+@[^[:space:]@\;\|\&\$\`]+$ ]] || die 1 "Invalid --alert-email address: $a"
    done
    for a in "${ALERT_WEBHOOKS[@]}"; do [[ "$a" =~ ^https?:// ]] || die 1 "--alert-webhook must be an http(s) URL: $(redact_url "$a")"; done
    return 0
}

validate() {
    FROM="$(to_unix_path "$FROM")"; OUTPUT_DIR="$(to_unix_path "$OUTPUT_DIR")"; LOG_FILE="$(to_unix_path "$LOG_FILE")"
    PG_BIN="$(to_unix_path "$PG_BIN")"; MAP_FILE="$(to_unix_path "$MAP_FILE")"; BACKUP_DIR="$(to_unix_path "$BACKUP_DIR")"
    PG_DUMP_WRAPPER="$(to_unix_path "$PG_DUMP_WRAPPER")"; SERVERS_FILE="$(to_unix_path "$SERVERS_FILE")"
    [[ -n "$FROM" ]] || die 1 "--from FILE|DIR is required (see --help)"
    [[ -e "$FROM" ]] || die 1 "--from not found: $FROM"
    if [[ -z "$SERVERS_FILE" ]] && { [[ ! "$DB_PORT" =~ ^[0-9]+$ ]] || (( DB_PORT < 1 || DB_PORT > 65535 )); }; then die 1 "Invalid port: $DB_PORT"; fi
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die 1 "--jobs must be a positive integer (got '$JOBS')"
    (( SCHEMA_ONLY && DATA_ONLY )) && die 1 "--schema-only and --data-only are mutually exclusive"
    (( DATA_ONLY && CLEAN )) && die 1 "--clean cannot be used with --data-only"
    (( IF_EXISTS && !CLEAN )) && die 1 "--if-exists requires --clean"
    case "${BACKUP_METHOD,,}" in dump|psql) BACKUP_METHOD="${BACKUP_METHOD,,}" ;; *) die 1 "--backup-first / backup_method must be 'dump' or 'psql' (got '$BACKUP_METHOD')" ;; esac
    (( BACKUP_FIRST && FORCE )) && die 1 "--backup-first and --force cannot be used together"
    [[ -n "$BACKUP_SCHEMA" ]] || die 1 "--backup-schema must not be empty"
    [[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]] || die 1 "--min-free-mb must be an integer"
    if [[ -n "$PGPASSFILE_OPT" ]]; then
        PGPASSFILE_OPT="$(to_unix_path "$PGPASSFILE_OPT")"
        [[ -r "$PGPASSFILE_OPT" ]] || die 1 "pgpassfile not readable: $PGPASSFILE_OPT"
        PGPASSFILE="$(native_path "$PGPASSFILE_OPT")"; export PGPASSFILE
    fi
    if [[ -n "$SERVERS_FILE" ]]; then
        MULTI=1
        [[ -z "$CLI_HOST_PORT_OPT" ]] || die 1 "$CLI_HOST_PORT_OPT cannot be used with --servers: host and port come from each line of the servers file"
        (( PROMPT_PASSWORD )) && die 1 "-W cannot be used with --servers (each server has its own password)." \
            "Put one line per server in ~/.pgpass (%APPDATA%\\postgresql\\pgpass.conf on Windows) or use --pgpassfile FILE: host:port:*:user:password"
        (( CONF_HOST_PORT )) && log_warn "host=/port= in the config file are ignored: --servers sets them for each server"
        load_servers_file
    else
        SRV_HOSTS=("$DB_HOST"); SRV_PORTS=("$DB_PORT"); SRV_USERS=("$DB_USER"); SRV_DBS=("")
    fi
    BASE_USER="$DB_USER"
    return 0
}

load_servers_file() {
    local file="$SERVERS_FILE" line lineno=0 host port user dbs
    local -A seen=()
    [[ -r "$file" && ! -d "$file" ]] || die 1 "Servers file not readable: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1)); line="${line//$CR/}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        host=""; port=""; user=""; dbs=""
        IFS=',' read -r host port user dbs <<<"$line"
        host="$(trim "$host")"; port="$(trim "$port")"; user="$(trim "$user")"; dbs="$(trim "$dbs")"
        [[ -n "$host" && "$host" != *[[:space:]]* ]] || die 1 "Servers file $file:$lineno: host is missing or has spaces (expected $SERVERS_LINE_FORMAT)"
        if [[ ! "$port" =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
            die 1 "Servers file $file:$lineno: invalid port '$port' for host $host (expected $SERVERS_LINE_FORMAT)"
        fi
        port=$(( 10#$port ))
        [[ "${dbs,,}" == "$SERVERS_ALL_KEYWORD" ]] && dbs=""
        [[ -z "${seen[$host:$port]:-}" ]] || die 1 "Servers file $file:$lineno: $host:$port is already listed on line ${seen[$host:$port]}"
        seen[$host:$port]=$lineno
        SRV_HOSTS+=("$host"); SRV_PORTS+=("$port"); SRV_USERS+=("$user"); SRV_DBS+=("$dbs")
    done <"$file"
    (( ${#SRV_HOSTS[@]} )) || die 1 "Servers file $file lists no servers (expected $SERVERS_LINE_FORMAT lines)"
}

use_server() {   # point DB_HOST/DB_PORT/DB_USER/SERVER_LABEL at server <index>
    DB_HOST="${SRV_HOSTS[$1]}"; DB_PORT="${SRV_PORTS[$1]}"; DB_USER="${SRV_USERS[$1]:-$BASE_USER}"
    if (( MULTI )); then SERVER_LABEL="$DB_HOST:$DB_PORT"; else SERVER_LABEL=""; fi
}
server_list() { local i out=""; for i in "${!SRV_HOSTS[@]}"; do out+="${out:+, }${SRV_HOSTS[$i]}:${SRV_PORTS[$i]}"; done; printf '%s' "$out"; }

prompt_password() {
    (( PROMPT_PASSWORD )) || return 0
    local fd pw=""
    { exec {fd}<>"$TTY_DEVICE"; } 2>/dev/null || die 1 "-W needs a terminal to type the password. Use ~/.pgpass or --pgpassfile instead."
    printf 'Password for user %s@%s:%s: ' "$DB_USER" "$DB_HOST" "$DB_PORT" >&"$fd"
    IFS= read -r -s -u "$fd" pw || true
    printf '\n' >&"$fd"; exec {fd}>&-
    pw="${pw%"$CR"}"
    [[ -n "$pw" ]] || die 1 "No password entered (-W)."
    export PGPASSWORD="$pw"; pw=""
}

# ----------------------------------------------------------------------------
# Sources: find dumps, keep the newest of each, map each to a database
# ----------------------------------------------------------------------------
detect_format() {   # detect_format <path> -> custom|directory|tar|plain|plain-gz|unsupported|none
    local p="$1" n="${1##*/}" head
    if [[ -d "$p" ]]; then if [[ -f "$p/$DIR_FORMAT_TOC" ]]; then echo directory; else echo none; fi; return 0; fi
    [[ -f "$p" ]] || { echo none; return 0; }
    if [[ "$n" == *"$PLAIN_GZ_EXT" ]]; then echo plain-gz; return 0; fi
    if [[ "$n" == *"$PLAIN_EXT" ]]; then echo plain; return 0; fi
    if [[ "$n" =~ $UNSUPPORTED_EXT_RE ]]; then echo unsupported; return 0; fi
    head="$(head -c "${#ARCHIVE_MAGIC}" -- "$p" 2>/dev/null | tr -d '\0')" || head=""
    if [[ "$head" == "$ARCHIVE_MAGIC" ]]; then echo custom; return 0; fi
    head="$(dd if="$p" bs=1 skip="$TAR_MAGIC_OFFSET" count="${#TAR_MAGIC}" 2>/dev/null | tr -d '\0')" || head=""
    if [[ "$head" == "$TAR_MAGIC" ]]; then echo tar; return 0; fi
    echo none
}

glob_any() {   # glob_any <name> <pattern...>
    local n="$1" p; shift
    for p in "$@"; do
        # shellcheck disable=SC2053  # intentional glob match
        [[ "$n" == $p ]] && return 0
    done
    return 1
}

load_map_file() {
    [[ -n "$MAP_FILE" ]] || return 0
    [[ -r "$MAP_FILE" ]] || die 1 "Map file not readable: $MAP_FILE"
    local line lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1)); line="${line//$CR/}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" == *=* ]] || die 1 "Map file $MAP_FILE:$lineno: expected FILE=DB"
        MAPS+=("$(trim "${line%%=*}")=$(trim "${line#*=}")")
    done <"$MAP_FILE"
}

validate_maps() {
    local m
    for m in "${MAPS[@]}"; do
        [[ "$m" == *=* && -n "$(trim "${m%%=*}")" && -n "$(trim "${m#*=}")" ]] || die 1 "Invalid --map '$m' (expected FILE=DB, e.g. 'salesdb_*=salesdb')"
    done
}

map_db() {   # map_db <file-name> -> database ('' = unmapped)
    local n="$1" m pat
    for m in "${MAPS[@]}"; do
        pat="${m%%=*}"
        # shellcheck disable=SC2053  # intentional glob match
        if [[ "$n" == $pat ]]; then printf '%s' "${m#*=}"; return 0; fi
    done
    return 0
}

add_source() {   # add_source <path> <format>
    SRC_PATHS+=("$1"); SRC_NAMES+=("${1##*/}"); SRC_FORMATS+=("$2"); SRC_SIZES+=("$(size_of "$1")"); SRC_SUMS+=("-"); SRC_DBS+=("")
}

discover_sources() {
    local fmt
    [[ "$FROM" == / ]] || FROM="${FROM%/}"
    fmt="$(detect_format "$FROM")"
    if [[ -f "$FROM" || "$fmt" == directory ]]; then    # one dump
        case "$fmt" in none|unsupported) die 1 "Not a dump pg_restore or psql can read: $FROM" ;; esac
        [[ -n "$TARGET_DB" ]] || die 2 "--from FILE needs -d DB (the target database; nothing is guessed from the file name). Nothing was restored."
        if (( ${#MAPS[@]} )) || [[ -n "$MAP_FILE" ]]; then log_warn "--map/--map-file ignored for a single --from FILE (using -d $TARGET_DB)"; fi
        add_source "$FROM" "$fmt"; SRC_DBS[0]="$TARGET_DB"
        return 0
    fi
    [[ -z "$TARGET_DB" ]] || die 1 "-d is only for a single --from FILE; for a folder use --map FILE=DB or --map-file"
    load_map_file
    validate_maps
    local -a entries=() kept=(); local p n key i
    local -A by_key=()
    while IFS= read -r -d '' p; do entries+=("$p"); done < <(find "$FROM" -mindepth 1 -maxdepth 1 -print0 | sort -z)
    for p in "${entries[@]}"; do
        n="${p##*/}"
        [[ "$n" =~ $IGNORED_FILE_RE ]] && continue
        fmt="$(detect_format "$p")"
        case "$fmt" in
            none) if [[ -d "$p" ]]; then log_debug "Skipping sub-folder (not a directory-format dump): $p"; else log_debug "Skipping (not a dump): $p"; fi; continue ;;
            unsupported) log_warn "Skipping unsupported compressed SQL file (only $PLAIN_EXT and $PLAIN_GZ_EXT): $p"; continue ;;
        esac
        if (( ${#INCLUDES[@]} )) && ! glob_any "$n" "${INCLUDES[@]}"; then log_debug "Not selected by --include: $n"; continue; fi
        if (( ${#EXCLUDES[@]} )) && glob_any "$n" "${EXCLUDES[@]}"; then log_info "Excluded by --exclude: $n"; continue; fi
        key="$n"
        [[ "$n" =~ $DUMP_DATE_RE ]] && key="${BASH_REMATCH[1]}|${BASH_REMATCH[3]}"
        if [[ -n "${by_key[$key]:-}" ]]; then
            SKIPPED_OLDER+=("${kept[${by_key[$key]}]%|*}")
            kept[${by_key[$key]}]="$p|$fmt"           # names sort by date, so this one is newer
        else
            by_key[$key]=${#kept[@]}; kept+=("$p|$fmt")
        fi
    done
    (( ${#kept[@]} )) || die 2 "No dump files selected in $FROM (check --include/--exclude)"
    for i in "${kept[@]}"; do add_source "${i%|*}" "${i##*|}"; done
    log_info "Source $FROM: ${#SRC_PATHS[@]} dump file(s) selected${SKIPPED_OLDER[*]:+, ${#SKIPPED_OLDER[@]} older file(s) skipped}"
    for p in "${SKIPPED_OLDER[@]}"; do log_info "Skipping older dump (a newer file of the same dump is selected): $p"; done
    local -a unmapped=(); local db
    for i in "${!SRC_PATHS[@]}"; do
        db="$(map_db "${SRC_NAMES[$i]}")"
        SRC_DBS[i]="$db"
        [[ -n "$db" ]] || unmapped+=("${SRC_NAMES[$i]}")
    done
    if (( ${#unmapped[@]} )); then
        for n in "${unmapped[@]}"; do log_error "No --map for selected file: $n"; done
        die 2 "${#unmapped[@]} selected file(s) have no target database. Add --map 'FILE=DB' (globs allowed) or a --map-file line for each, or leave them out with --exclude. Nothing was restored."
    fi
    return 0
}

show_file_map() {
    local i w=0
    for i in "${!SRC_NAMES[@]}"; do (( ${#SRC_NAMES[$i]} > w )) && w=${#SRC_NAMES[$i]}; done
    log_info "File map (${#SRC_PATHS[@]}):"
    for i in "${!SRC_NAMES[@]}"; do
        log_info "$(printf "  %-${w}s -> %s  (%s, %s)" "${SRC_NAMES[$i]}" "${SRC_DBS[$i]}" "${SRC_SIZES[$i]}" "${SRC_FORMATS[$i]}")"
    done
}

verify_checksums() {
    local i sum dir out
    for i in "${!SRC_PATHS[@]}"; do
        sum="${SRC_PATHS[$i]}$CHECKSUM_SUFFIX"
        if (( !CHECKSUM )); then SRC_SUMS[i]="off"; continue; fi
        if [[ ! -f "$sum" ]]; then SRC_SUMS[i]="missing"; log_warn "No checksum file for ${SRC_NAMES[$i]} (restoring without verification)"; continue; fi
        dir="$(dirname -- "${SRC_PATHS[$i]}")"
        if out="$(cd "$dir" && sha256_check "${sum##*/}" 2>&1)"; then
            SRC_SUMS[i]="OK"; log_info "Checksum OK: ${SRC_NAMES[$i]}"
        else
            strip_cr out; SRC_SUMS[i]="FAILED"
            log_error "Checksum FAILED: ${SRC_NAMES[$i]}: ${out//$'\n'/ }"
        fi
    done
}

# Tables a dump would create or fill, honouring -n / -t.
dump_tables() {   # dump_tables <src-index> -> "schema<FS>table" lines (cached)
    local i="$1" out line rest sch tbl owner x lines=""
    if [[ -n "${SRC_TABLES[$i]+x}" ]]; then printf '%s' "${SRC_TABLES[$i]}"; return 0; fi
    local -a sel=()
    for x in "${INCLUDE_SCHEMAS[@]}"; do sel+=(--schema="$x"); done
    for x in "${INCLUDE_TABLES[@]}"; do sel+=(--table="$x"); done
    case "${SRC_FORMATS[$i]}" in
        plain|plain-gz)
            if [[ "${SRC_FORMATS[$i]}" == plain ]]; then out="$(grep -E '^CREATE (UNLOGGED )?TABLE ' -- "${SRC_PATHS[$i]}" || true)"
            else out="$(gzip -dc -- "${SRC_PATHS[$i]}" | grep -E '^CREATE (UNLOGGED )?TABLE ' || true)"; fi
            local re='^CREATE (UNLOGGED )?TABLE ("[^"]+"|[^. ]+)\.("[^"]+"|[^ (]+)'
            while IFS= read -r line; do
                [[ "$line" =~ $re ]] || continue
                sch="${BASH_REMATCH[2]}"; tbl="${BASH_REMATCH[3]}"; sch="${sch//\"/}"; tbl="${tbl//\"/}"
                lines+="$sch$FIELD_SEP$tbl"$'\n'
            done <<<"$out" ;;
        *)
            if ! out="$("$(bin pg_restore)" --list "${sel[@]}" -- "$(native_path "${SRC_PATHS[$i]}")" 2>&1)"; then
                strip_cr out; log_warn "Cannot read the table list of ${SRC_NAMES[$i]}: ${out%%$'\n'*}"; out=""
            fi
            strip_cr out
            local re='^[0-9]+; [0-9]+ [0-9]+ TABLE( DATA)? (.*)$'
            while IFS= read -r line; do
                [[ "$line" =~ $re ]] || continue
                rest="${BASH_REMATCH[2]}"; sch="${rest%% *}"; rest="${rest#* }"; owner="${rest##* }"; tbl="${rest% "$owner"}"
                lines+="$sch$FIELD_SEP$tbl"$'\n'
            done <<<"$out" ;;
    esac
    SRC_TABLES[$i]="$(sort -u <<<"$lines" | sed '/^$/d')"
    [[ -n "${SRC_TABLES[$i]}" ]] && SRC_TABLES[$i]+=$'\n'
    printf '%s' "${SRC_TABLES[$i]}"
}

# ----------------------------------------------------------------------------
# Target checks and plan
# ----------------------------------------------------------------------------
psql_q() {   # psql_q <db> <sql>  -> unaligned, tuples only, FIELD_SEP separated
    local out rc=0
    out="$("$(bin psql)" -X -w -A -t -q -v ON_ERROR_STOP=1 -F "$FIELD_SEP" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$1" -c "$2" 2>&1)" || rc=$?
    strip_cr out; printf '%s' "$out"; return "$rc"
}

server_ready() {
    if (( !SKIP_PRECHECK )) && command -v "$(bin pg_isready)" >/dev/null 2>&1; then
        "$(bin pg_isready)" -q -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -t "$PG_ISREADY_TIMEOUT" \
            || { SRV_ERR="Server not accepting connections at $DB_HOST:$DB_PORT (pg_isready)"; return 1; }
    fi
    local out
    out="$(psql_q "$MAINTENANCE_DB" "SELECT current_setting('server_version_num')")" \
        || { SRV_ERR="Cannot connect to '$MAINTENANCE_DB' on $DB_HOST:$DB_PORT as '$DB_USER': ${out//$'\n'/ }"; return 1; }
    log_info "Connected: server_version_num=$out"
    return 0
}

# One unit per (source file, target database) on this server.
plan_server() {   # plan_server <srv-index>
    local s="$1" i db out t tables existing overlap n
    local -A dbs_exist=() wanted=() tables_of=()
    local -a want=()
    if [[ -n "${SRV_DBS[$s]}" ]]; then add_list want "${SRV_DBS[$s]}"; for db in "${want[@]}"; do wanted[$db]=1; done; fi
    out="$(psql_q "$MAINTENANCE_DB" "SELECT datname FROM pg_database WHERE NOT datistemplate")" \
        || { SRV_ERR="Cannot list databases: ${out//$'\n'/ }"; return 1; }
    while IFS= read -r db; do [[ -n "$db" ]] && dbs_exist[$db]=1; done <<<"$out"
    for i in "${!SRC_PATHS[@]}"; do
        db="${SRC_DBS[$i]}"
        if (( ${#wanted[@]} )) && [[ -z "${wanted[$db]:-}" ]]; then
            log_info "${SRC_NAMES[$i]} -> $db: not restored on this server (servers file lists ${SRV_DBS[$s]})"; continue
        fi
        U_SRV+=("$s"); U_SRC+=("$i"); U_DB+=("$db"); U_OVERLAP+=(""); U_PRE_RC+=(0); U_PRE_STAGE+=("-"); U_PRE_MSG+=("")
        n=$(( ${#U_SRV[@]} - 1 ))
        if [[ "${SRC_SUMS[$i]}" == FAILED ]]; then
            U_STATE+=("checksum"); U_PRE_RC[n]=4; U_PRE_STAGE[n]="checksum"; U_PRE_MSG[n]="checksum FAILED, will not be restored"; continue
        fi
        if [[ -z "${dbs_exist[$db]:-}" ]]; then
            if (( CREATE )); then U_STATE+=("new")
            else U_STATE+=("missing"); U_PRE_RC[n]=2; U_PRE_STAGE[n]="precheck"; U_PRE_MSG[n]="database does not exist (add --create), will not be restored"; fi
            continue
        fi
        U_STATE+=("exists")
        if [[ -z "${tables_of[$db]+x}" ]]; then
            if ! out="$(psql_q "$db" "SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p') AND n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema' ORDER BY 1, 2")"; then
                U_STATE[n]="error"; U_PRE_RC[n]=2; U_PRE_STAGE[n]="precheck"; U_PRE_MSG[n]="cannot read its tables: ${out%%$'\n'*}"; continue
            fi
            tables_of[$db]="$out"$'\n'
        fi
        existing="${tables_of[$db]}"
        tables="$(dump_tables "$i")"
        overlap=""
        while IFS= read -r t; do
            [[ -n "$t" ]] || continue
            grep -qxF -- "$t" <<<"$existing" && overlap+="$t"$'\n'
        done <<<"$tables"
        U_OVERLAP[n]="$overlap"
        [[ -n "$overlap" ]] && bk_add "$s" "$db" "$overlap"
    done
    return 0
}

bk_add() {   # bk_add <srv> <db> <lines>
    local key="$1|$2" t
    if [[ -z "${BK_NEED[$key]+x}" ]]; then BK_NEED[$key]=""; BK_KEYS+=("$key"); fi
    while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        grep -qxF -- "$t" <<<"${BK_NEED[$key]}" || BK_NEED[$key]+="$t"$'\n'
    done <<<"$3"
}

existing_count() { local k n=0 c; for k in "${BK_KEYS[@]}"; do c="$(grep -c . <<<"${BK_NEED[$k]}" || true)"; n=$(( n + c )); done; printf '%d' "$n"; }
pretty_tables() { local t out=""; while IFS= read -r t; do [[ -n "$t" ]] && out+="${out:+, }${t%%"$FIELD_SEP"*}.${t#*"$FIELD_SEP"}"; done <<<"$1"; printf '%s' "$out"; }
runnable_units() { local n c=0; for n in "${!U_SRV[@]}"; do (( U_PRE_RC[n] == 0 )) && c=$((c + 1)); done; printf '%d' "$c"; }
servers_to_restore() { local n; local -A s=(); for n in "${!U_SRV[@]}"; do (( U_PRE_RC[n] == 0 )) && s[${U_SRV[$n]}]=1; done; printf '%d' "${#s[@]}"; }

# ----------------------------------------------------------------------------
# RESTORE SUMMARY
# ----------------------------------------------------------------------------
options_text() {
    local o="" x
    (( CLEAN )) && o+=" --clean"; (( IF_EXISTS )) && o+=" --if-exists"; (( CREATE )) && o+=" --create"
    (( JOBS > 1 )) && o+=" -j $JOBS"; (( SCHEMA_ONLY )) && o+=" --schema-only"; (( DATA_ONLY )) && o+=" --data-only"
    for x in "${INCLUDE_SCHEMAS[@]}"; do o+=" -n $x"; done
    for x in "${INCLUDE_TABLES[@]}"; do o+=" -t $x"; done
    (( NO_OWNER )) && o+=" --no-owner"; (( NO_PRIVILEGES )) && o+=" --no-privileges"; [[ -n "$ROLE" ]] && o+=" --role $ROLE"
    (( EXIT_ON_ERROR )) && o+=" --exit-on-error"; (( ${#EXTRA_ARGS[@]} )) && o+=" -- ${EXTRA_ARGS[*]}"
    o="${o# }"; printf '%s' "${o:-(none)}"
}

unit_state_text() {   # unit_state_text <unit>
    local n="$1" c
    case "${U_STATE[$n]}" in
        exists) c="$(grep -c . <<<"${U_OVERLAP[$n]}" || true)"
                if (( c )); then printf 'exists, %d table(s) will be overwritten' "$c"; else printf 'exists, no tables in common'; fi ;;
        new)    printf 'new, will be created' ;;
        *)      printf '%s' "${U_PRE_MSG[$n]}" ;;
    esac
}

backup_text() {
    local count; count="$(existing_count)"
    (( count )) || { printf 'none needed (no existing tables will be overwritten)'; return 0; }
    case "$BACKUP_STATE" in
        planned) if [[ "$CHOSEN_METHOD" == psql ]]; then printf '%d table(s) psql copy -> %s.<table>%s%s' "$count" "$BACKUP_SCHEMA" "$BACKUP_NAME_TAG" "$RUN_STAMP"
                 else printf '%d table(s) via %s -> %s/' "$count" "$DUMP_WRAPPER_NAME" "$BACKUP_DIR"; fi ;;
        done)    printf '%d table(s) already backed up (%s); rollback commands are printed at the end' "$count" "$CHOSEN_METHOD" ;;
        skipped) printf 'NONE - %s %d confirmed, %d table(s) overwritten without a backup' "$APPROVE_OVERWRITE_WORD" "$count" "$count" ;;
        forced)  printf 'NONE - --force, %d table(s) overwritten without a backup' "$count" ;;
        *)       printf '%d table(s) need a backup' "$count" ;;
    esac
}

print_summary() {
    local s n w=0 i first sums ok=0 miss=0 bad=0 srcsize lead
    for i in "${!SRC_NAMES[@]}"; do (( ${#SRC_NAMES[$i]} > w )) && w=${#SRC_NAMES[$i]}; done
    for i in "${!SRC_SUMS[@]}"; do case "${SRC_SUMS[$i]}" in OK) ok=$((ok + 1)) ;; missing) miss=$((miss + 1)) ;; FAILED) bad=$((bad + 1)) ;; esac; done
    if (( !CHECKSUM )); then sums="not checked (--no-checksum)"
    else sums="$ok OK"; (( miss )) && sums+=", $miss missing"; (( bad )) && sums+=", $bad FAILED"; fi
    srcsize="$(du -shc -- "${SRC_PATHS[@]}" 2>/dev/null | tail -n1 | cut -f1)" || srcsize="?"
    {
        echo ""
        echo "RESTORE SUMMARY"
        if (( MULTI )); then echo "  Targets    : $(servers_to_restore) of ${#SRV_HOSTS[@]} server(s) will be restored ($SERVERS_FILE)"
        else echo "  Target     : $DB_HOST:$DB_PORT  user=$DB_USER"; fi
        echo "  Source     : $FROM  (${#SRC_PATHS[@]} file(s), ${srcsize}${SKIPPED_OLDER[*]:+; ${#SKIPPED_OLDER[@]} older file(s) skipped})"
        for s in "${!SRV_HOSTS[@]}"; do
            if (( MULTI )); then
                printf '  Server %-3s : %s:%s  user=%s  databases=%s\n' "$((s + 1))" "${SRV_HOSTS[$s]}" "${SRV_PORTS[$s]}" "${SRV_USERS[$s]:-$BASE_USER}" "${SRV_DBS[$s]:-$SERVERS_ALL_KEYWORD}"
                if [[ "${SRV_OK[$s]:-0}" != 1 ]]; then echo "               (unreachable - will not be restored)"; continue; fi
            fi
            first=1
            for n in "${!U_SRV[@]}"; do
                [[ "${U_SRV[$n]}" == "$s" ]] || continue
                if (( first )); then lead="  Files      :"; else lead="              "; fi
                printf '%s %-*s -> %s  (%s)\n' "$lead" "$w" "${SRC_NAMES[${U_SRC[$n]}]}" "${U_DB[$n]}" "$(unit_state_text "$n")"
                first=0
            done
            (( first )) && echo "  Files      : (none selected for this server)"
        done
        echo "  Options    : $(options_text)"
        echo "  Checksums  : $sums"
        echo "  Backup     : $(backup_text)"
        echo ""
    } | log_block
}

list_existing_warning() {
    local k s db
    log_warn "$(existing_count) existing table(s) would be overwritten by this restore:"
    for k in "${BK_KEYS[@]}"; do
        s="${k%%|*}"; db="${k#*|}"
        log_warn "  ${SRV_HOSTS[$s]}:${SRV_PORTS[$s]}/$db: $(pretty_tables "${BK_NEED[$k]}")"
    done
}

# ----------------------------------------------------------------------------
# Pre-restore backups
# ----------------------------------------------------------------------------
resolve_dump_wrapper() {
    local here
    if [[ -n "$PG_DUMP_WRAPPER" ]]; then
        [[ -r "$PG_DUMP_WRAPPER" ]] && return 0
        SRV_ERR="--pg-dump-wrapper not found: $PG_DUMP_WRAPPER"; return 1
    fi
    here="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -r "$here/$DUMP_WRAPPER_NAME" ]]; then PG_DUMP_WRAPPER="$here/$DUMP_WRAPPER_NAME"; return 0; fi
    if command -v "$DUMP_WRAPPER_NAME" >/dev/null 2>&1; then PG_DUMP_WRAPPER="$(command -v "$DUMP_WRAPPER_NAME")"; return 0; fi
    SRV_ERR="$DUMP_WRAPPER_NAME not found next to this script or on PATH; use --pg-dump-wrapper FILE (or --backup-first=psql)"; return 1
}

dump_backup_cmd() {   # dump_backup_cmd <srv> <db> <tables>  -> BK_CMD
    local s="$1" db="$2" t
    BK_CMD=(bash "${PG_DUMP_WRAPPER:-$DUMP_WRAPPER_NAME}" -h "${SRV_HOSTS[$s]}" -p "${SRV_PORTS[$s]}" -U "${SRV_USERS[$s]:-$BASE_USER}" -d "$db"
            -F custom --checksum --table-sizes 0 --min-free-mb "$MIN_FREE_MB" -o "$BACKUP_DIR/${SRV_HOSTS[$s]}_${SRV_PORTS[$s]}")
    [[ -n "$PGPASSFILE_OPT" ]] && BK_CMD+=(--pgpassfile "$PGPASSFILE_OPT")
    [[ -n "$PG_BIN" ]] && BK_CMD+=(--pg-bin "$PG_BIN")
    while IFS= read -r t; do [[ -n "$t" ]] && BK_CMD+=(-t "$(qname "${t%%"$FIELD_SEP"*}" "${t#*"$FIELD_SEP"}")"); done <<<"$3"
    return 0
}

backup_name() {   # backup_name <srv> <db> <table> -> BK_NAME = unused <table>_bkp_<stamp>[_N]
    local base="$3" suffix="$BACKUP_NAME_TAG$RUN_STAMP" cand k=1 out
    (( ${#base} + ${#suffix} > PG_MAX_IDENT - 3 )) && base="${base:0:$(( PG_MAX_IDENT - 3 - ${#suffix} ))}"
    cand="$base$suffix"
    while :; do
        if [[ -z "${BK_USED["$1|$2|$cand"]:-}" ]]; then
            out="$(psql_q "$2" "SELECT to_regclass($(quote_literal "$(qname "$BACKUP_SCHEMA" "$cand")")) IS NULL")" || out="t"
            [[ "$out" == t ]] && break
        fi
        k=$((k + 1)); cand="$base${suffix}_$k"
    done
    BK_USED["$1|$2|$cand"]=1; BK_NAME="$cand"
}

backup_fail() {   # backup_fail <db> <secs> <message>
    log_error "$3"
    record "$(label_for "$1")" 5 backup "-" "$2" "-"
    DB_NAME=""
    return 5
}

run_backups() {   # run_backups <method>  -> 0 ok, 5 any failure (stops at the first)
    local method="$1" k s db t sch tbl out rc file sql rows start cols
    BACKUP_STATE="planned"; CHOSEN_METHOD="$method"
    if [[ "$method" == dump ]] && ! resolve_dump_wrapper; then log_error "$SRV_ERR"; record "-" 5 backup "-" 0 "-"; return 5; fi
    log_info "Starting pre-restore backups ($method): $(existing_count) table(s)"
    for k in "${BK_KEYS[@]}"; do
        s="${k%%|*}"; db="${k#*|}"; use_server "$s"; DB_NAME="$db"; start=$SECONDS
        if [[ "$method" == dump ]]; then
            dump_backup_cmd "$s" "$db" "${BK_NEED[$k]}"
            log_info "Backing up $(pretty_tables "${BK_NEED[$k]}") with $DUMP_WRAPPER_NAME"
            log_info "Command: $(print_cmd "${BK_CMD[@]}")"
            rc=0; out="$("${BK_CMD[@]}" 2>&1)" || rc=$?
            strip_cr out
            while IFS= read -r t; do log_debug "  $DUMP_WRAPPER_NAME: $t"; done <<<"$out"
            file=""; [[ "$(grep -E "$DUMP_WRAPPER_DONE_RE" <<<"$out" | tail -n1)" =~ $DUMP_WRAPPER_DONE_RE ]] && file="${BASH_REMATCH[1]}"
            if (( rc != 0 )) || [[ -z "$file" ]]; then
                backup_fail "$db" $(( SECONDS - start )) "$DUMP_WRAPPER_NAME failed (exit $rc): $(grep -E '\[ERROR\]' <<<"$out" | tail -n3 | tr '\n' ' ')"; return 5
            fi
            log_info "$DUMP_WRAPPER_NAME OK: $file ($(size_of "$file"), $(fmt_duration $(( SECONDS - start ))))"
            while IFS= read -r t; do [[ -n "$t" ]] && BK_ROWS+=("$s|$db|dump|$t|$file|-"); done <<<"${BK_NEED[$k]}"
        else
            if [[ "$(psql_q "$db" "SELECT to_regnamespace($(quote_literal "$(quote_ident "$BACKUP_SCHEMA")")) IS NULL")" == t ]]; then
                out="$(psql_q "$db" "${ROLE:+SET ROLE $(quote_ident "$ROLE"); }CREATE SCHEMA IF NOT EXISTS $(quote_ident "$BACKUP_SCHEMA")")" \
                    || { backup_fail "$db" 0 "Cannot create backup schema $BACKUP_SCHEMA: ${out//$'\n'/ }"; return 5; }
                log_info "Created backup schema $BACKUP_SCHEMA"
            fi
            while IFS= read -r t; do
                [[ -n "$t" ]] || continue
                sch="${t%%"$FIELD_SEP"*}"; tbl="${t#*"$FIELD_SEP"}"
                backup_name "$s" "$db" "$tbl"
                cols="$(psql_q "$db" "SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) FROM pg_attribute WHERE attrelid = $(quote_literal "$(qname "$sch" "$tbl")")::regclass AND attnum > 0 AND NOT attisdropped AND attgenerated = ''")" \
                    && [[ -n "$cols" ]] || { backup_fail "$db" $(( SECONDS - start )) "Cannot read the columns of $sch.$tbl: ${cols//$'\n'/ }"; return 5; }
                sql="${ROLE:+SET ROLE $(quote_ident "$ROLE"); }CREATE TABLE $(qname "$BACKUP_SCHEMA" "$BK_NAME") (LIKE $(qname "$sch" "$tbl") INCLUDING ALL); INSERT INTO $(qname "$BACKUP_SCHEMA" "$BK_NAME") ($cols) OVERRIDING SYSTEM VALUE SELECT $cols FROM $(qname "$sch" "$tbl");"
                log_info "Backing up $sch.$tbl with psql -> $BACKUP_SCHEMA.$BK_NAME"
                log_debug "SQL: $sql"
                rc=0; out="$("$(bin psql)" -X -w -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$db" -c "$sql" 2>&1)" || rc=$?
                strip_cr out
                (( rc == 0 )) || { backup_fail "$db" $(( SECONDS - start )) "psql copy of $sch.$tbl failed: ${out//$'\n'/ }"; return 5; }
                rows="$(grep -oE '^INSERT 0 [0-9]+' <<<"$out" | awk '{print $3}')" || rows=""
                log_info "psql copy OK: $BACKUP_SCHEMA.$BK_NAME (${rows:-?} rows)"
                BK_COLS[${#BK_ROWS[@]}]="$cols"
                BK_ROWS+=("$s|$db|psql|$sch$FIELD_SEP$tbl|$BACKUP_SCHEMA$FIELD_SEP$BK_NAME|${rows:-?}")
            done <<<"${BK_NEED[$k]}"
        fi
        DB_NAME=""
    done
    SERVER_LABEL=""
    BACKUP_STATE="done"
    log_info "Pre-restore backups finished OK ($method)"
    return 0
}

print_backup_commands() {   # shown when the run refuses to overwrite
    local k s db
    resolve_dump_wrapper || true
    log_info "Back them up first, for example:"
    for k in "${BK_KEYS[@]}"; do
        s="${k%%|*}"; db="${k#*|}"
        dump_backup_cmd "$s" "$db" "${BK_NEED[$k]}"
        print_cmd "${BK_CMD[@]}" | log_block
    done
    log_info "or re-run with --backup-first (dump), --backup-first=psql, or --force to skip the backup."
}

# shellcheck disable=SC2329  # called from the EXIT trap via write_rollback
rollback_text() {
    local i r s db method tbl target rows sch name host self src dst cols
    (( ${#BK_ROWS[@]} )) || return 0
    self="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$SCRIPT_NAME"
    local -A dump_done=()
    for i in "${!BK_ROWS[@]}"; do
        r="${BK_ROWS[$i]}"
        IFS='|' read -r s db method tbl target rows <<<"$r"
        host="${SRV_HOSTS[$s]}:${SRV_PORTS[$s]}"; sch="${tbl%%"$FIELD_SEP"*}"; name="${tbl#*"$FIELD_SEP"}"
        if [[ "$method" == psql ]]; then
            src="$(qname "$sch" "$name")"; dst="$(qname "${target%%"$FIELD_SEP"*}" "${target#*"$FIELD_SEP"}")"; cols="${BK_COLS[$i]}"
            printf '# %s/%s %s.%s  (psql copy -> %s.%s, %s rows)\n' "$host" "$db" "$sch" "$name" "${target%%"$FIELD_SEP"*}" "${target#*"$FIELD_SEP"}" "$rows"
            printf "psql -h %s -p %s -U %s -d %s -v ON_ERROR_STOP=1 <<'SQL'\n" "${SRV_HOSTS[$s]}" "${SRV_PORTS[$s]}" "${SRV_USERS[$s]:-$BASE_USER}" "$(printf '%q' "$db")"
            printf 'BEGIN;\nTRUNCATE %s;\nINSERT INTO %s (%s) OVERRIDING SYSTEM VALUE SELECT %s FROM %s;\nCOMMIT;\n-- when no longer needed: DROP TABLE %s;\nSQL\n\n' \
                "$src" "$src" "$cols" "$cols" "$dst" "$dst"
        else
            [[ -n "${dump_done[$target]:-}" ]] && continue
            dump_done[$target]=1
            printf '# %s/%s  (%s backup -> %s)\n' "$host" "$db" "$DUMP_WRAPPER_NAME" "$target"
            printf '%s\n\n' "$(print_cmd bash "$self" -h "${SRV_HOSTS[$s]}" -p "${SRV_PORTS[$s]}" -U "${SRV_USERS[$s]:-$BASE_USER}" --from "$target" -d "$db" --clean --if-exists --force)"
        fi
    done
}

warn_no_clean() {   # existing tables + no --clean: pg_restore errors with "already exists" and appends rows
    (( CLEAN || DATA_ONLY )) && return 0
    (( $(existing_count) > 0 )) || return 0
    log_warn "--clean is not set: restoring over existing tables gives 'already exists' / duplicate key errors (FAIL(3)) and can add rows to the old data. For a full replace add --clean --if-exists."
}

# ----------------------------------------------------------------------------
# Restore
# ----------------------------------------------------------------------------
label_for() { printf '%s' "${SERVER_LABEL:+$SERVER_LABEL/}$1"; }

record() {   # record <label> <rc|skipped> <stage> <size> <secs> <file>
    RESULTS+=("${1//|/_}|$2|$3|$4|$5|$6")
    if [[ "$2" != skipped && "$2" != 0 ]]; then
        if (( $2 > WORST )); then WORST=$2; FIRST_FAIL="$3 ($1)"; fi   # stage of the row that sets the exit code
    fi
    return 0
}

build_restore_cmd() {   # build_restore_cmd <unit>  -> RCMD (array), RPIPE ('' or the plain .sql/.sql.gz path fed to psql)
    local i="${U_SRC[$1]}" db="${U_DB[$1]}" x fmt
    fmt="${SRC_FORMATS[$i]}"; RPIPE=""
    if [[ "$fmt" == plain || "$fmt" == plain-gz ]]; then
        RCMD=("$(bin psql)" -X -w -q -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$db")
        [[ -n "$ROLE" ]] && RCMD+=(-c "SET ROLE $(quote_ident "$ROLE")")
        RCMD+=(-f -); RPIPE="${SRC_PATHS[$i]}"
        (( ${#EXTRA_ARGS[@]} )) && RCMD+=("${EXTRA_ARGS[@]}")
        return 0
    fi
    RCMD=("$(bin pg_restore)" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$db" --no-password)
    if (( JOBS > 1 )); then
        if [[ "$fmt" == tar ]]; then log_warn "-j ignored for tar dump ${SRC_NAMES[$i]} (pg_restore limitation)"; else RCMD+=(--jobs="$JOBS"); fi
    fi
    (( CLEAN )) && RCMD+=(--clean); (( IF_EXISTS )) && RCMD+=(--if-exists)
    (( SCHEMA_ONLY )) && RCMD+=(--schema-only); (( DATA_ONLY )) && RCMD+=(--data-only)
    for x in "${INCLUDE_SCHEMAS[@]}"; do RCMD+=(--schema="$x"); done
    for x in "${INCLUDE_TABLES[@]}"; do RCMD+=(--table="$x"); done
    (( NO_OWNER )) && RCMD+=(--no-owner); (( NO_PRIVILEGES )) && RCMD+=(--no-privileges)
    [[ -n "$ROLE" ]] && RCMD+=(--role="$ROLE")
    (( EXIT_ON_ERROR )) && RCMD+=(--exit-on-error)
    (( VERBOSE )) && RCMD+=(--verbose)
    (( ${#EXTRA_ARGS[@]} )) && RCMD+=("${EXTRA_ARGS[@]}")
    RCMD+=("$(native_path "${SRC_PATHS[$i]}")")
    return 0
}

create_cmd() {   # create_cmd <db> -> CCMD
    CCMD=("$(bin psql)" -X -w -q -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$MAINTENANCE_DB")
    [[ -n "$ROLE" ]] && CCMD+=(-c "SET ROLE $(quote_ident "$ROLE")")
    CCMD+=(-c "CREATE DATABASE $(quote_ident "$1")")
}

plain_reader() {   # plain_reader <file>: SQL text, minus owner / privilege lines when asked
    local -a filt=()
    (( NO_OWNER )) && filt+=(-e "/$PLAIN_OWNER_LINE_RE/d")
    (( NO_PRIVILEGES )) && filt+=(-e "/$PLAIN_PRIV_LINE_RE/d")
    (( ${#filt[@]} )) || filt=(-e '')
    if [[ "$1" == *"$PLAIN_GZ_EXT" ]]; then gzip -dc -- "$1" | sed -E "${filt[@]}"; else sed -E "${filt[@]}" -- "$1"; fi
}

plain_reader_text() {   # how plain_reader is shown in logs / dry-run
    local f=""
    (( NO_OWNER )) && f+=" -e '/$PLAIN_OWNER_LINE_RE/d'"
    (( NO_PRIVILEGES )) && f+=" -e '/$PLAIN_PRIV_LINE_RE/d'"
    if [[ "$1" == *"$PLAIN_GZ_EXT" ]]; then printf 'gzip -dc %q%s | ' "$1" "${f:+ | sed -E$f}"
    elif [[ -n "$f" ]]; then printf 'sed -E%s %q | ' "$f" "$1"
    else printf 'cat %q | ' "$1"; fi
}

run_child() {   # run_child <outfile> <gz-or-''> cmd...  (background child, so INT/TERM are handled at once)
    local out="$1" gz="$2" rc=0; shift 2
    if [[ -n "$gz" ]]; then ( set -o pipefail; plain_reader "$gz" | "$@" ) >"$out" 2>&1 &
    else "$@" >"$out" 2>&1 & fi
    CHILD_PID=$!
    wait "$CHILD_PID" || rc=$?
    CHILD_PID=""
    return "$rc"
}

restore_unit() {   # restore_unit <unit>
    local n="$1" i="${U_SRC[$1]}" db="${U_DB[$1]}" start=$SECONDS rc=0 out l label
    use_server "${U_SRV[$n]}"; DB_NAME="$db"; label="$(label_for "$db")"; CUR_UNIT=$n
    out="$(mktemp "${TMPDIR:-/tmp}/pg_restore_wrapper.XXXXXX")"
    if [[ "${U_STATE[$n]}" == new && -z "${CREATED["${U_SRV[$n]}|$db"]:-}" ]]; then
        create_cmd "$db"
        STAGE="create"; log_info "Creating database $db (--create; it does not exist)"
        if ! run_child "$out" "" "${CCMD[@]}"; then
            log_error "CREATE DATABASE failed: $(tr '\n\r' '  ' <"$out")"
            record "$label" 3 create "${SRC_SIZES[$i]}" $(( SECONDS - start )) "${SRC_PATHS[$i]}"
            rm -f "$out"; DB_NAME=""; CUR_UNIT=-1; return 0
        fi
        CREATED["${U_SRV[$n]}|$db"]=1
    fi
    build_restore_cmd "$n"
    STAGE="restore"
    log_info "Starting restore (${SRC_FORMATS[$i]}) <- ${SRC_PATHS[$i]}"
    log_info "Command: ${RPIPE:+$(plain_reader_text "$RPIPE")}$(print_cmd "${RCMD[@]}")"
    run_child "$out" "$RPIPE" "${RCMD[@]}" || rc=$?
    while IFS= read -r l; do
        l="${l%"$CR"}"; [[ -n "$l" ]] || continue
        if [[ "$l" == *"error:"* || "$l" == *ERROR:* ]]; then log_error "$l"; else log_info "$l"; fi
    done <"$out"
    if (( rc != 0 )) && grep -qE "$OWNER_ERROR_RE" "$out" && (( !NO_OWNER )); then
        log_warn "Hint: the dump sets owners this login cannot switch to (normal on Aurora/RDS, where the master user is not a superuser). Re-run with --no-owner, or --role ROLE."
    fi
    rm -f "$out"
    if (( rc != 0 )); then
        log_error "Restore failed (exit $rc) after $(fmt_duration $(( SECONDS - start )))"
        record "$label" 3 restore "${SRC_SIZES[$i]}" $(( SECONDS - start )) "${SRC_PATHS[$i]}"
    else
        log_info "Restore finished in $(fmt_duration $(( SECONDS - start )))"
        record "$label" 0 - "${SRC_SIZES[$i]}" $(( SECONDS - start )) "${SRC_PATHS[$i]}"
    fi
    DB_NAME=""; CUR_UNIT=-1
    return 0
}

# ----------------------------------------------------------------------------
# Summary table, alerts, exit
# ----------------------------------------------------------------------------
summary_lines() {
    local r db rc stage size dur file status w=24 head="DATABASE"
    (( MULTI )) && head="SERVER/DATABASE"
    for r in "${RESULTS[@]}"; do db="${r%%|*}"; (( ${#db} > w )) && w=${#db}; done
    printf "%-${w}s %-9s %-10s %-8s %-8s %s\n" "$head" "STATUS" "STAGE" "SIZE" "TIME" "FILE"
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r db rc stage size dur file <<<"$r"
        if [[ "$rc" == skipped ]]; then status="SKIPPED"; stage="-"; dur="-"
        elif (( rc == 0 )); then status="OK"; stage="-"; dur="$(fmt_duration "$dur")"
        else status="FAIL($rc)"; dur="$(fmt_duration "$dur")"; fi
        printf "%-${w}s %-9s %-10s %-8s %-8s %s\n" "$db" "$status" "$stage" "$size" "$dur" "$file"
    done
}

redact_text() { sed -E 's/(password[[:space:]]*[=:][[:space:]]*)[^[:space:]]+/\1*****/Ig; s#(://[^:/@[:space:]]+:)[^@/[:space:]]+@#\1*****@#g'; }

db_list() {
    local n out=""; local -A seen=()
    for n in "${!U_DB[@]}"; do [[ -n "${seen[${U_DB[$n]}]:-}" ]] || { seen[${U_DB[$n]}]=1; out+="${out:+ }${U_DB[$n]}"; }; done
    [[ -n "$out" ]] || out="${TARGET_DB:--}"
    printf '%s' "$out"
}

build_alert_body() {
    local rc="$1" status="$2"
    {
        printf 'pg_restore_wrapper %s on %s\n\n' "$status" "$(host_name)"
        if (( MULTI )); then printf 'Servers    : %s (from %s)\n' "$(server_list)" "$SERVERS_FILE"
        else printf 'Server     : %s:%s (user %s)\n' "${SRV_HOSTS[0]:-$DB_HOST}" "${SRV_PORTS[0]:-$DB_PORT}" "${SRV_USERS[0]:-$DB_USER}"; fi
        printf 'Databases  : %s\n' "$(db_list)"
        printf 'Source     : %s\n' "${FROM:--}"
        printf 'Exit code  : %s\n' "$rc"
        (( rc != 0 )) && printf 'Failed at  : %s\n' "$STAGE"
        printf 'Started    : %s\n' "$RUN_START_TS"
        printf 'Duration   : %s\n' "$(fmt_duration $(( SECONDS - RUN_START )))"
        printf 'Output dir : %s\n' "$OUTPUT_DIR"
        printf 'Log file   : %s\n' "$LOG_FILE"
        [[ -n "$ROLLBACK_FILE" ]] && printf 'Rollback   : %s\n' "$ROLLBACK_FILE"
        (( ${#RESULTS[@]} )) && { printf '\n'; summary_lines; }
        if (( rc != 0 )) && [[ -r "$LOG_FILE" ]]; then printf '\nLast %s log lines:\n' "$ALERT_LOG_LINES"; tail -n "$ALERT_LOG_LINES" "$LOG_FILE"; fi
    } | redact_text
}

build_alert_json() {
    local rc="$1" status="$2" body="$3" r db drc stage size dur file first=1 rows="" tailtxt=""
    if [[ "$ALERT_WEBHOOK_FORMAT" == slack ]]; then
        local head="${body%%$'\n'*}" rest="${body#*$'\n'}"
        printf '{"text": "%s"}' "$(json_escape "*${head}*"$'\n''```'"${rest}"'```')"; return 0
    fi
    for r in "${RESULTS[@]}"; do
        IFS='|' read -r db drc stage size dur file <<<"$r"
        (( first )) || rows+=","; first=0
        rows+="$(printf '{"database":"%s","exit_code":"%s","stage":"%s","size":"%s","duration_seconds":"%s","file":"%s"}' \
            "$(json_escape "$db")" "$(json_escape "$drc")" "$(json_escape "$stage")" "$(json_escape "$size")" "$(json_escape "$dur")" "$(json_escape "$file")")"
    done
    if (( rc != 0 )) && [[ -r "$LOG_FILE" ]]; then tailtxt="$(tail -n "$ALERT_LOG_LINES" "$LOG_FILE" | redact_text)"; fi
    printf '{"status":"%s","exit_code":%d,"failed_stage":"%s","host":"%s","server":"%s","source":"%s","started":"%s","duration_seconds":%d,"output_dir":"%s","log_file":"%s","rollback_file":"%s","databases":[%s],"log_tail":"%s","text":"%s"}' \
        "$(json_escape "$status")" "$rc" "$( (( rc != 0 )) && json_escape "$STAGE")" "$(json_escape "$(host_name)")" "$(json_escape "$(server_list)")" \
        "$(json_escape "$FROM")" "$(json_escape "$RUN_START_TS")" $(( SECONDS - RUN_START )) "$(json_escape "$OUTPUT_DIR")" "$(json_escape "$LOG_FILE")" \
        "$(json_escape "$ROLLBACK_FILE")" "$rows" "$(json_escape "$tailtxt")" "$(json_escape "$body")"
}

send_email_alert() {
    local subject="$1" body="$2" mailer="" to; local -a tmo=()
    command -v timeout >/dev/null 2>&1 && tmo=(timeout 60)
    if command -v mail >/dev/null 2>&1; then mailer="mail"
    elif command -v mailx >/dev/null 2>&1; then mailer="mailx"
    elif command -v sendmail >/dev/null 2>&1; then mailer="sendmail"
    elif [[ -x /usr/sbin/sendmail ]]; then mailer=/usr/sbin/sendmail
    else log_warn "Alert: no mail/mailx/sendmail found; cannot send e-mail to ${ALERT_EMAILS[*]}"; return 1; fi
    if [[ "$mailer" == mail || "$mailer" == mailx ]]; then
        local -a from=(); [[ -n "$ALERT_FROM" ]] && from=(-r "$ALERT_FROM")
        printf '%s\n' "$body" | "${tmo[@]}" "$mailer" "${from[@]}" -s "$subject" -- "${ALERT_EMAILS[@]}"
    else
        to="$(IFS=,; printf '%s' "${ALERT_EMAILS[*]}")"
        { [[ -n "$ALERT_FROM" ]] && printf 'From: %s\n' "$ALERT_FROM"
          printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' "$to" "$subject" "$body"; } | "${tmo[@]}" "$mailer" -t -oi
    fi
}

send_webhook_alert() {
    local url="$1" json="$2" out
    command -v curl >/dev/null 2>&1 || { log_warn "Alert: curl not installed; webhook skipped"; return 1; }
    out="$(printf 'url = "%s"\n' "${url//\"/\\\"}" | curl -sS --fail --max-time 20 --retry 2 \
            -H 'Content-Type: application/json' --data-binary "$json" -o /dev/null -w '%{http_code}' -K - 2>&1)" \
        || { log_warn "Alert: webhook $(redact_url "$url") failed: ${out%%$'\n'*}"; return 1; }
    log_info "Alert: webhook $(redact_url "$url") -> HTTP $out"
}

send_alerts() {
    local rc="$1" mode="${2:-}" status subject body json url dbs
    (( ${#ALERT_EMAILS[@]} + ${#ALERT_WEBHOOKS[@]} )) || return 0
    if [[ "$mode" != test && "$ALERT_ON" == failure ]] && (( rc == 0 )); then return 0; fi
    if [[ "$mode" == test ]]; then status="TEST"; elif (( rc == 0 )); then status="SUCCESS"; else status="FAILED"; fi
    dbs="$(db_list)"; (( ${#dbs} > 60 )) && dbs="${dbs:0:57}..."
    subject="[pg_restore_wrapper] $status: $dbs on ${SRV_HOSTS[0]:-$DB_HOST} (exit $rc)"
    (( MULTI )) && subject="[pg_restore_wrapper] $status: ${#SRV_HOSTS[@]} server(s) from ${SERVERS_FILE##*/} (exit $rc)"
    body="$(build_alert_body "$rc" "$status")"
    if (( ${#ALERT_EMAILS[@]} )); then
        if send_email_alert "$subject" "$body"; then log_info "Alert: e-mail sent to ${ALERT_EMAILS[*]}"; else log_warn "Alert: e-mail to ${ALERT_EMAILS[*]} failed"; fi
    fi
    if (( ${#ALERT_WEBHOOKS[@]} )); then
        json="$(build_alert_json "$rc" "$status" "$subject"$'\n\n'"$body")"
        for url in "${ALERT_WEBHOOKS[@]}"; do send_webhook_alert "$url" "$json" || true; done
    fi
    return 0
}

# shellcheck disable=SC2329  # called from the EXIT trap
write_rollback() {
    local txt; txt="$(rollback_text)"
    [[ -n "$txt" ]] || return 0
    log_info "Rollback commands (from the pre-restore backup):"
    printf '%s\n' "$txt" | log_block
    ROLLBACK_FILE="$OUTPUT_DIR/$ROLLBACK_FILE_PREFIX$(date '+%Y%m%d_%H%M%S')$ROLLBACK_FILE_EXT"
    if printf '#!/usr/bin/env bash\n# Rollback for the pg_restore_wrapper run started %s. Review before running: bash %s\nset -e\n\n%s\n' "$RUN_START_TS" "$ROLLBACK_FILE" "$txt" >"$ROLLBACK_FILE" 2>/dev/null; then
        log_info "Rollback commands saved (review, then run with bash): $ROLLBACK_FILE"
    else ROLLBACK_FILE=""; fi
}

# shellcheck disable=SC2317  # called from the EXIT trap
# shellcheck disable=SC2329  # called from trap
on_exit() {
    local rc=$? l
    (( PROMPT_PASSWORD )) && unset PGPASSWORD
    trap - EXIT INT TERM
    set +e
    SERVER_LABEL=""; DB_NAME=""
    (( MAIN_STARTED )) || exit "$rc"
    write_rollback
    if (( ${#RESULTS[@]} )); then log_info "Summary:"; while IFS= read -r l; do _log INFO "  $l"; done < <(summary_lines); fi
    if (( CANCELLED )); then _log WARN "Cancelled - nothing was restored"; exit "$rc"; fi
    if (( rc == 0 )); then _log INFO "Run finished OK in $(fmt_duration $(( SECONDS - RUN_START )))"
    else _log ERROR "Run finished with exit code $rc (stage: $STAGE)"; fi
    send_alerts "$rc" || true
    exit "$rc"
}

# shellcheck disable=SC2317  # invoked indirectly via trap
# shellcheck disable=SC2329  # called from trap
on_signal() {
    _log ERROR "Interrupted by signal $1"
    if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
        pkill -TERM -P "$CHILD_PID" 2>/dev/null || true
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    local n
    if (( CUR_UNIT >= 0 )); then
        use_server "${U_SRV[$CUR_UNIT]}"
        record "$(label_for "${U_DB[$CUR_UNIT]}")" 130 interrupted "${SRC_SIZES[${U_SRC[$CUR_UNIT]}]}" 0 "${SRC_PATHS[${U_SRC[$CUR_UNIT]}]}"
        for (( n = CUR_UNIT + 1; n < ${#U_SRV[@]}; n++ )); do
            (( U_PRE_RC[n] == 0 )) || continue
            use_server "${U_SRV[$n]}"; record "$(label_for "${U_DB[$n]}")" skipped - "${SRC_SIZES[${U_SRC[$n]}]}" 0 "${SRC_PATHS[${U_SRC[$n]}]}"
        done
    fi
    STAGE="interrupted"
    exit 130
}

# ----------------------------------------------------------------------------
# Gates: existing tables, approval
# ----------------------------------------------------------------------------
refuse() { STAGE="precheck"; die 2 "$@"; }
cancel() { CANCELLED=1; STAGE="cancelled"; die 2 "$@"; }

mark_rest_skipped() {   # every planned unit -> SKIPPED (used when no restore will start)
    local n
    for n in "${!U_SRV[@]}"; do
        (( U_PRE_RC[n] == 0 )) || continue
        use_server "${U_SRV[$n]}"; record "$(label_for "${U_DB[$n]}")" skipped - "${SRC_SIZES[${U_SRC[$n]}]}" 0 "${SRC_PATHS[${U_SRC[$n]}]}"
    done
    SERVER_LABEL=""
}

existing_tables_gate() {
    local count ans brc=0
    count="$(existing_count)"
    (( count )) || return 0
    if (( FORCE )); then BACKUP_STATE="forced"; log_warn "--force: $count existing table(s) will be overwritten without a backup"; return 0; fi
    if (( BACKUP_FIRST )); then BACKUP_STATE="planned"; CHOSEN_METHOD="$BACKUP_METHOD"; return 0; fi
    list_existing_warning
    if (( DRY_RUN )); then
        log_info "DRY RUN - would ask: back them up first? [dump / psql / skip / cancel]"
        BACKUP_STATE="planned"; CHOSEN_METHOD="$BACKUP_METHOD"; return 0
    fi
    if (( ASSUME_YES )) || ! have_tty; then
        print_backup_commands
        local why="no terminal to ask"; (( ASSUME_YES )) && why="--yes never overwrites tables without a backup"
        refuse "$count existing table(s) would be overwritten and neither --backup-first nor --force was given ($why). Nothing was restored."
    fi
    tty_ask "Back them up first? [dump / psql / skip / cancel]: " ans
    case "${ans,,}" in
        dump|psql)
            STAGE="backup"; run_backups "${ans,,}" || brc=$?
            if (( brc )); then mark_rest_skipped; die 5 "Pre-restore backup failed; no restore was started."; fi ;;
        skip)
            tty_ask "Type $APPROVE_OVERWRITE_WORD $count to restore WITHOUT a backup, anything else cancels: " ans
            [[ "$ans" == "$APPROVE_OVERWRITE_WORD $count" ]] || cancel "Not confirmed ('${ans:-<empty>}' is not '$APPROVE_OVERWRITE_WORD $count'); cancelled. Nothing was restored."
            BACKUP_STATE="skipped"; log_warn "$APPROVE_OVERWRITE_WORD $count confirmed: no backup will be taken" ;;
        *)
            cancel "Cancelled at the existing-tables prompt ('${ans:-<empty>}'). Nothing was restored." ;;
    esac
}

approval_text() { if (( MULTI )); then printf '%s %d' "$APPROVE_SERVERS_WORD" "$(servers_to_restore)"; else printf '%s' "${SRV_HOSTS[0]}"; fi; }

approval_gate() {
    local ans expect; expect="$(approval_text)"
    if (( ASSUME_YES )); then log_info "Approval skipped (--yes)"; return 0; fi
    have_tty || refuse "No terminal to approve the restore and --yes was not given; refusing. Use --yes for cron/scripts. Nothing was restored."
    if (( MULTI )); then tty_ask "Type $expect to continue, anything else cancels: " ans
    else tty_ask "Type the target host name to continue ($expect), anything else cancels: " ans; fi
    [[ "$ans" == "$expect" ]] || cancel "Approval not given ('${ans:-<empty>}' is not '$expect'); cancelled. Nothing was restored."
    log_info "Approval accepted ($expect)"
}

dry_run_commands() {
    local n k s db t
    local -A made=()
    if [[ "$BACKUP_STATE" == planned ]] && (( $(existing_count) )); then
        log_info "DRY RUN - pre-restore backup ($CHOSEN_METHOD) would run:"
        [[ "$CHOSEN_METHOD" == dump ]] && { resolve_dump_wrapper || log_warn "$SRV_ERR"; }
        for k in "${BK_KEYS[@]}"; do
            s="${k%%|*}"; db="${k#*|}"
            if [[ "$CHOSEN_METHOD" == dump ]]; then dump_backup_cmd "$s" "$db" "${BK_NEED[$k]}"; print_cmd "${BK_CMD[@]}" | log_block
            else
                while IFS= read -r t; do
                    [[ -n "$t" ]] || continue
                    printf '%s:%s/%s: CREATE TABLE %s (LIKE %s INCLUDING ALL); INSERT INTO ... (non-generated columns) OVERRIDING SYSTEM VALUE SELECT ... FROM %s;\n' \
                        "${SRV_HOSTS[$s]}" "${SRV_PORTS[$s]}" "$db" "$(qname "$BACKUP_SCHEMA" "${t#*"$FIELD_SEP"}$BACKUP_NAME_TAG$RUN_STAMP")" \
                        "$(qname "${t%%"$FIELD_SEP"*}" "${t#*"$FIELD_SEP"}")" "$(qname "${t%%"$FIELD_SEP"*}" "${t#*"$FIELD_SEP"}")" | log_block
                done <<<"${BK_NEED[$k]}"
            fi
        done
    fi
    log_info "DRY RUN - restore commands:"
    for n in "${!U_SRV[@]}"; do
        (( U_PRE_RC[n] == 0 )) || continue
        use_server "${U_SRV[$n]}"
        if [[ "${U_STATE[$n]}" == new && -z "${made["${U_SRV[$n]}|${U_DB[$n]}"]:-}" ]]; then
            create_cmd "${U_DB[$n]}"; print_cmd "${CCMD[@]}" | log_block; made["${U_SRV[$n]}|${U_DB[$n]}"]=1
        fi
        build_restore_cmd "$n"
        printf '%s%s\n' "${RPIPE:+$(plain_reader_text "$RPIPE")}" "$(print_cmd "${RCMD[@]}")" | log_block
    done
    SERVER_LABEL=""
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    parse_args "$@"
    trap on_exit EXIT
    RUN_START_TS="$(_ts)"; RUN_STAMP="$(date "+$BACKUP_STAMP_FORMAT")"
    STAGE="validate"
    validate_alerts
    if (( ALERT_TEST )); then
        OUTPUT_DIR="$(to_unix_path "$OUTPUT_DIR")"; mkdir -p "$OUTPUT_DIR" 2>/dev/null || true
        [[ -n "$LOG_FILE" ]] || LOG_FILE="$OUTPUT_DIR/$DEFAULT_LOG_NAME"
        log_info "Sending test alert..."; send_alerts 0 test; exit 0
    fi
    (( DRY_RUN )) || MAIN_STARTED=1
    validate
    if (( !DRY_RUN )); then
        mkdir -p "$OUTPUT_DIR" || die 2 "Cannot create output dir: $OUTPUT_DIR"
        [[ -w "$OUTPUT_DIR" ]] || die 2 "Output dir not writable: $OUTPUT_DIR"
    fi
    OUTPUT_DIR="$(cd "$OUTPUT_DIR" 2>/dev/null && pwd || printf '%s' "$OUTPUT_DIR")"
    [[ -n "$LOG_FILE" ]] || LOG_FILE="$OUTPUT_DIR/$DEFAULT_LOG_NAME"
    [[ -n "$BACKUP_DIR" ]] || BACKUP_DIR="$OUTPUT_DIR/$DEFAULT_BACKUP_SUBDIR"
    if (( MULTI )); then log_info "===== $SCRIPT_NAME v$SCRIPT_VERSION: ${#SRV_HOSTS[@]} server(s) from $SERVERS_FILE: $(server_list) ====="
    else log_info "===== $SCRIPT_NAME v$SCRIPT_VERSION: host=$DB_HOST port=$DB_PORT user=$DB_USER ====="; fi
    (( DRY_RUN )) && log_info "DRY RUN - nothing will be created, backed up or restored"

    STAGE="precheck"
    local tool free_kb s n
    for tool in pg_restore psql; do command -v "$(bin "$tool")" >/dev/null 2>&1 || die 2 "$tool not found (install postgresql-client or use --pg-bin)"; done
    log_info "Using $("$(bin pg_restore)" --version | tr -d "$CR") ($(command -v "$(bin pg_restore)"))"
    (( DRY_RUN )) || log_info "Log file: $LOG_FILE"
    if (( !SKIP_PRECHECK )); then
        free_kb="$(free_kb_of "$OUTPUT_DIR")"
        if [[ "$free_kb" =~ ^[0-9]+$ ]]; then
            log_info "Free space in $OUTPUT_DIR: $(( free_kb / 1024 )) MB"
            (( free_kb / 1024 < MIN_FREE_MB )) && log_warn "Free space $(( free_kb / 1024 )) MB is below --min-free-mb $MIN_FREE_MB MB"
        fi
    fi
    discover_sources
    show_file_map
    verify_checksums
    prompt_password

    for s in "${!SRV_HOSTS[@]}"; do
        use_server "$s"; SRV_OK[s]=0
        (( MULTI )) && log_info "Server $((s + 1))/${#SRV_HOSTS[@]}: user=$DB_USER databases=${SRV_DBS[$s]:-$SERVERS_ALL_KEYWORD}"
        if ! server_ready || ! plan_server "$s"; then
            (( MULTI )) || die 2 "$SRV_ERR"
            log_error "$SRV_ERR"
            record "$SERVER_LABEL" 2 precheck - 0 -
            continue
        fi
        SRV_OK[s]=1
    done
    for n in "${!U_SRV[@]}"; do
        (( U_PRE_RC[n] == 0 )) && continue
        use_server "${U_SRV[$n]}"; DB_NAME="${U_DB[$n]}"
        log_error "${SRC_NAMES[${U_SRC[$n]}]}: ${U_PRE_MSG[$n]}"; DB_NAME=""
        record "$(label_for "${U_DB[$n]}")" "${U_PRE_RC[$n]}" "${U_PRE_STAGE[$n]}" "${SRC_SIZES[${U_SRC[$n]}]}" 0 "${SRC_PATHS[${U_SRC[$n]}]}"
    done
    use_server 0; SERVER_LABEL=""
    if (( $(runnable_units) == 0 )); then
        print_summary
        STAGE="${FIRST_FAIL:-precheck}"
        die "$(( WORST ? WORST : 2 ))" "Nothing to restore."
    fi

    warn_no_clean
    existing_tables_gate
    print_summary
    if (( DRY_RUN )); then
        dry_run_commands
        if (( ASSUME_YES )); then log_info "DRY RUN - approval: skipped (--yes)"; else log_info "DRY RUN - approval would be required: type $(approval_text)"; fi
        (( ${#ALERT_EMAILS[@]} + ${#ALERT_WEBHOOKS[@]} )) && log_info "DRY RUN - alerts (on $ALERT_ON) -> ${#ALERT_EMAILS[@]} e-mail, ${#ALERT_WEBHOOKS[@]} webhook target(s)"
        exit "$WORST"
    fi
    approval_gate
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM

    if [[ "$BACKUP_STATE" == planned ]]; then
        STAGE="backup"
        local brc=0; run_backups "$CHOSEN_METHOD" || brc=$?
        if (( brc )); then mark_rest_skipped; die 5 "Pre-restore backup failed; no restore was started."; fi
    fi

    STAGE="restore"
    local stop=0
    for n in "${!U_SRV[@]}"; do
        (( U_PRE_RC[n] == 0 )) || continue
        if (( stop )); then
            use_server "${U_SRV[$n]}"; record "$(label_for "${U_DB[$n]}")" skipped - "${SRC_SIZES[${U_SRC[$n]}]}" 0 "${SRC_PATHS[${U_SRC[$n]}]}"; continue
        fi
        restore_unit "$n"
        if (( STOP_ON_ERROR )) && [[ "${RESULTS[-1]}" != *"|0|-|"* ]]; then log_error "Stopping after the first failure (--stop-on-error)"; stop=1; fi
    done
    SERVER_LABEL=""
    if (( WORST )); then STAGE="$FIRST_FAIL"; exit "$WORST"; fi
    STAGE="done"
    exit 0
}

main "$@"
