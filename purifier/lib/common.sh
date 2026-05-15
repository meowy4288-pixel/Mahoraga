# common.sh - shared utilities for purifier

# --- Default configuration ---
PURIFIER_SESSION_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/purifier/sessions"
PURIFIER_TIMEOUT="30m"
PURIFIER_TMPFS_SIZE="1G"
PURIFIER_MOUNT_OPTS="size=${PURIFIER_TMPFS_SIZE},nr_inodes=64k"

# --- Colors ---
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; NC=''
fi

# --- Logging ---
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()       { log_error "$@"; exit 1; }

# --- Session ID ---
generate_session_id() {
    uuidgen | tr A-Z a-z | cut -d- -f1-2
}

# --- Parse common flags (--session, --force) ---
# Sets globals: session_id, force_flag, parsed_rest
parse_common_flags() {
    session_id="${session_id:-}"
    force_flag="${force_flag:-0}"
    parsed_rest=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session) session_id="$2"; shift 2 ;;
            --force)   force_flag=1; shift ;;
            --)        shift; parsed_rest+=("$@"); break ;;
            *)         parsed_rest+=("$1"); shift ;;
        esac
    done
}

# --- Session resolution ---
# Returns session_id or dies
resolve_session() {
    local sid="${1:-}"
    if [[ -z "${sid}" ]]; then
        sid="$(detect_session_from_cwd)" || true
    fi
    if [[ -z "${sid}" ]]; then
        sid="$(find_single_active_session)" || true
    fi
    if [[ -z "${sid}" ]]; then
        die "No session specified and no active session found."
    fi
    echo "${sid}"
}

detect_session_from_cwd() {
    local dir="${PWD}"
    while [[ "${dir}" != "/" ]]; do
        if [[ -f "${dir}/.purifier-session" ]]; then
            cat "${dir}/.purifier-session" 2>/dev/null
            return 0
        fi
        dir="$(dirname "${dir}")"
    done
    return 1
}

find_single_active_session() {
    local sessions=()
    while IFS= read -r -d '' f; do
        sessions+=("$(basename "$(dirname "${f}")")")
    done < <(find "${PURIFIER_SESSION_DIR}" -mindepth 2 -maxdepth 2 -name 'project_path' -print0 2>/dev/null)
    if [[ ${#sessions[@]} -eq 1 ]]; then
        echo "${sessions[0]}"
    elif [[ ${#sessions[@]} -gt 1 ]]; then
        return 1
    fi
    return 1
}

# --- Session metadata helpers ---
session_dir()     { echo "${PURIFIER_SESSION_DIR}/${1}"; }
session_file()    { echo "$(session_dir "${1}")/${2}"; }

session_get() {
    local sid="$1" key="$2"
    local f="$(session_file "${sid}" "${key}")"
    if [[ -f "${f}" ]]; then
        cat "${f}"
    fi
}

session_set() {
    local sid="$1" key="$2" val="$3"
    mkdir -p "$(session_dir "${sid}")"
    printf '%s\n' "${val}" > "$(session_file "${sid}" "${key}")"
}

session_delete() {
    rm -rf "$(session_dir "${1}")"
}

session_exists() {
    [[ -d "$(session_dir "${1}")" ]]
}

# --- Sudo helpers ---
SUDO="sudo"
need_sudo() {
    if [[ $UID -eq 0 ]]; then
        SUDO=""
    fi
}

sudo_mount()      { ${SUDO} mount "$@"; }
sudo_umount()     { ${SUDO} umount "$@"; }
sudo_modprobe()   { ${SUDO} modprobe "$@"; }
sudo_mkdir()      { ${SUDO} mkdir -p "$@"; }

# --- Command execution ---
find_on_path() {
    command -v "$1" 2>/dev/null || which "$1" 2>/dev/null
}

# --- Cleanup trap helper ---
# Only for interrupts — EXIT trap is managed per-command.
DEFER_STACK=""
defer() {
    DEFER_STACK="${DEFER_STACK:+$DEFER_STACK$'\n'}$1"
}

defer_run() {
    local IFS=$'\n'
    local lines=(${DEFER_STACK})
    DEFER_STACK=""
    local i
    for (( i=${#lines[@]}-1; i>=0; i-- )); do
        eval "${lines[$i]}" 2>/dev/null || true
    done
}

# INT/TERM always run defer_run then exit (no-op when stack empty)
trap "defer_run; exit 1" INT TERM
