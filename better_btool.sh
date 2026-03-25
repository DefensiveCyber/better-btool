#!/usr/bin/env bash
# =============================================================================
# btool_filter.sh — Splunk btool wrapper with stanza-level filtering
#
# USAGE:
#   btool_filter.sh [OPTIONS] -- <btool args>
#
# EXAMPLES:
#   btool_filter.sh -e -- inputs list --debug
#   btool_filter.sh -d -- transforms list
#   btool_filter.sh -f "sourcetype" -- props list --debug
#   btool_filter.sh -e -f "monitor" -- inputs list --debug
#   btool_filter.sh -d -f "lookup" -- transforms list
#   btool_filter.sh -f "syslog" -C /opt/splunk -- inputs list --debug
#
# FLAGS (all optional, combinable):
#   -e            Show only stanzas where something is enabled
#                 (disabled = false, or key=1, or enabled = true)
#   -d            Show only stanzas where something is disabled
#                 (disabled = true, or enabled = false, or key=0)
#   -f <pattern>  Show only stanzas that contain <pattern> (case-insensitive)
#                 Can be used alone or combined with -e / -d
#   -C <path>     Path to Splunk home (default: $SPLUNK_HOME or /opt/splunk)
#   -b <path>     Full path to btool binary (overrides -C for binary location)
#   -o <file>     Write output to <file> in addition to stdout
#   -c <color>    Colorize stanza header lines (default: bcyan).
#                 Colors: red, green, yellow, blue, magenta, cyan, white
#                 Bold variants: bred, bgreen, byellow, bblue, bmagenta, bcyan, bwhite
#                 Use -c none to disable color entirely
#   -v            Verbose — show script debug info on stderr
#   -h            Show this help
#
# NOTES:
#   - Everything after -- is passed directly to btool (e.g. "inputs list --debug")
#   - If -e and -d are both given, stanzas matching either condition are shown
#   - The stanza header line ([stanza_name]) is always included in output
# =============================================================================

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
SPLUNK_HOME_DEFAULT="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_HOME_ARG=""
BTOOL_BIN=""
FILTER_ENABLED=false
FILTER_DISABLED=false
TEXT_FILTER=""
OUTPUT_FILE=""
COLOR="bcyan"
VERBOSE=false

# ── ANSI color map ────────────────────────────────────────────────────────────
declare -A ANSI_COLORS=(
    [red]="\033[0;31m"    [bred]="\033[1;31m"
    [green]="\033[0;32m"  [bgreen]="\033[1;32m"
    [yellow]="\033[0;33m" [byellow]="\033[1;33m"
    [blue]="\033[0;34m"   [bblue]="\033[1;34m"
    [magenta]="\033[0;35m"[bmagenta]="\033[1;35m"
    [cyan]="\033[0;36m"   [bcyan]="\033[1;36m"
    [white]="\033[0;37m"  [bwhite]="\033[1;37m"
)
ANSI_RESET="\033[0m"

# ── Helpers ──────────────────────────────────────────────────────────────────
log()  { "$VERBOSE" && echo "[DEBUG] $*" >&2 || true; }
die()  { echo "ERROR: $*" >&2; exit 1; }

usage() {
    sed -n '/^# USAGE:/,/^# =/{ /^# =/d; s/^# \{0,3\}//; p }' "$0"
    exit 0
}

# ── Parse flags ──────────────────────────────────────────────────────────────
while getopts ":edf:C:b:o:c:vh" opt; do
    case "$opt" in
        e) FILTER_ENABLED=true ;;
        d) FILTER_DISABLED=true ;;
        f) TEXT_FILTER="$OPTARG" ;;
        C) SPLUNK_HOME_ARG="$OPTARG" ;;
        b) BTOOL_BIN="$OPTARG" ;;
        o) OUTPUT_FILE="$OPTARG" ;;
        c) COLOR="$OPTARG" ;;
        v) VERBOSE=true ;;
        h) usage ;;
        :) die "Flag -$OPTARG requires an argument." ;;
        \?) die "Unknown flag: -$OPTARG  (use -h for help)" ;;
    esac
done
shift $((OPTIND - 1))

# ── Validate color ────────────────────────────────────────────────────────────
STANZA_COLOR=""
STANZA_RESET=""
if [[ -n "$COLOR" ]]; then
    COLOR_LC="${COLOR,,}"  # lowercase
    if [[ "$COLOR_LC" == "none" ]]; then
        STANZA_COLOR=""
        STANZA_RESET=""
        log "Stanza color: disabled"
    elif [[ -n "${ANSI_COLORS[$COLOR_LC]:-}" ]]; then
        STANZA_COLOR="${ANSI_COLORS[$COLOR_LC]}"
        STANZA_RESET="$ANSI_RESET"
        log "Stanza color: $COLOR_LC"
    else
        die "Unknown color '$COLOR'. Valid options: none, ${!ANSI_COLORS[*]}"
    fi
fi

# ── Consume the -- separator ─────────────────────────────────────────────────
if [[ "${1:-}" == "--" ]]; then
    shift
fi

[[ $# -eq 0 ]] && die "No btool arguments provided. Usage: $0 [OPTIONS] -- <btool args>  (try -h)"

# ── Resolve btool binary ──────────────────────────────────────────────────────
if [[ -z "$BTOOL_BIN" ]]; then
    SPLUNK_HOME_RESOLVED="${SPLUNK_HOME_ARG:-$SPLUNK_HOME_DEFAULT}"
    BTOOL_BIN="${SPLUNK_HOME_RESOLVED}/bin/splunk"
fi

log "btool binary: $BTOOL_BIN"
log "btool args:   btool $*"

[[ -x "$BTOOL_BIN" ]] || die "Splunk binary not found or not executable: $BTOOL_BIN\n       Set SPLUNK_HOME, use -C <path>, or use -b <path> to point directly to the binary."

# ── Run btool ─────────────────────────────────────────────────────────────────
log "Running: $BTOOL_BIN btool $*"
RAW_OUTPUT="$("$BTOOL_BIN" btool "$@" 2>&1)" || {
    echo "btool exited with an error:" >&2
    echo "$RAW_OUTPUT" >&2
    exit 1
}

# ── Stanza parser + filter ────────────────────────────────────────────────────
# Strategy:
#   1. Split the raw output into stanzas (blocks starting with a [header]).
#   2. For each stanza, apply the requested filters.
#   3. Print stanzas that pass all active filters.

filter_stanzas() {
    local raw="$1"
    local header=""
    local body=""
    local -a stanzas_headers=()
    local -a stanzas_bodies=()

    # ── Collect stanzas ───────────────────────────────────────────────────────
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[.*\]$ ]]; then
            # Save the previous stanza (if any)
            if [[ -n "$header" ]]; then
                stanzas_headers+=("$header")
                stanzas_bodies+=("$body")
            fi
            header="$line"
            body=""
        else
            # Append to current stanza body (skip blank separator lines between stanzas)
            if [[ -n "$header" ]]; then
                body+="${line}"$'\n'
            else
                # Lines before any stanza header (e.g. btool preamble) — print as-is
                echo "$line"
            fi
        fi
    done <<< "$raw"

    # Save the final stanza
    if [[ -n "$header" ]]; then
        stanzas_headers+=("$header")
        stanzas_bodies+=("$body")
    fi

    # ── Filter + emit ─────────────────────────────────────────────────────────
    local count=0
    local i
    for i in "${!stanzas_headers[@]}"; do
        local h="${stanzas_headers[$i]}"
        local b="${stanzas_bodies[$i]}"
        local full_stanza="${h}"$'\n'"${b}"

        # ── Text filter ───────────────────────────────────────────────────────
        if [[ -n "$TEXT_FILTER" ]]; then
            echo "$full_stanza" | grep -qi "$TEXT_FILTER" || continue
        fi

        # ── Enabled/disabled filter ───────────────────────────────────────────
        # "enabled" patterns:
        #   disabled = false  |  disabled = 0
        #   enabled  = true   |  enabled  = 1
        #   <key>    = 1      (generic boolean key set to 1)
        # "disabled" patterns:
        #   disabled = true   |  disabled = 1
        #   enabled  = false  |  enabled  = 0
        #   <key>    = 0

        local is_enabled=false
        local is_disabled=false

        # Check for explicit disabled/enabled keys
        if echo "$b" | grep -qi '^\s*disabled\s*=\s*\(false\|0\)\s*$'; then
            is_enabled=true
        fi
        if echo "$b" | grep -qi '^\s*enabled\s*=\s*\(true\|1\)\s*$'; then
            is_enabled=true
        fi
        if echo "$b" | grep -qi '^\s*disabled\s*=\s*\(true\|1\)\s*$'; then
            is_disabled=true
        fi
        if echo "$b" | grep -qi '^\s*enabled\s*=\s*\(false\|0\)\s*$'; then
            is_disabled=true
        fi

        # If neither explicit key exists, treat absence of disabled=true as enabled
        if ! echo "$b" | grep -qi '^\s*disabled\s*=' && \
           ! echo "$b" | grep -qi '^\s*enabled\s*='; then
            is_enabled=true   # implicitly enabled (no disabled key)
        fi

        local pass=true

        if "$FILTER_ENABLED" && "$FILTER_DISABLED"; then
            # Show stanzas that are either explicitly enabled OR disabled
            # (i.e. stanzas that have any enabled/disabled key at all)
            if ! "$is_enabled" && ! "$is_disabled"; then
                pass=false
            fi
        elif "$FILTER_ENABLED"; then
            "$is_enabled" || pass=false
        elif "$FILTER_DISABLED"; then
            "$is_disabled" || pass=false
        fi

        "$pass" || continue

        # ── Emit ──────────────────────────────────────────────────────────────
        printf "${STANZA_COLOR}%s${STANZA_RESET}\n" "$h"
        printf '%s' "$b" | sed 's/^\([^\[]\)/   \1/'
        echo ""   # blank line between stanzas for readability
        (( count++ )) || true
    done

    log "Stanzas emitted: $count"
}

# ── Execute filter and route output ──────────────────────────────────────────
if [[ -n "$OUTPUT_FILE" ]]; then
    filter_stanzas "$RAW_OUTPUT" | tee "$OUTPUT_FILE"
    log "Output also written to: $OUTPUT_FILE"
else
    filter_stanzas "$RAW_OUTPUT"
fi
