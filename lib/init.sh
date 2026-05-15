# init.sh - sandbox initialization

_purifier_cleanup() {
    if [[ -n "${DEFER_STACK:-}" ]]; then
        echo "" >&2
        log_warn "Sandbox initialization failed. Rolling back..."
        defer_run
    fi
}

cmd_init() {
    need_sudo

    # EXIT trap handles set -e induced exits during setup
    trap "_purifier_cleanup" EXIT
    # INT/TERM from common.sh also calls defer_run

    local timeout="${PURIFIER_TIMEOUT}"
    local project_path=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) timeout="$2"; shift 2 ;;
            --timeout=*) timeout="${1#*=}"; shift ;;
            --) shift; project_path="$*"; break ;;
            -*) die "Unknown option: $1" ;;
            *)  project_path="$1"; shift ;;
        esac
    done

    [[ -z "${project_path}" ]] && die "Usage: purifier init [--timeout <duration>] <project-path>"
    [[ ! -d "${project_path}" ]] && die "Project path does not exist or is not a directory: ${project_path}"

    project_path="$(realpath "${project_path}")"

    # Check for existing sandbox containment
    if detect_session_from_cwd &>/dev/null; then
        die "Already inside a purifier sandbox. Cannot nest sessions."
    fi
    # Check project path isn't itself inside a sandbox
    if ( cd "${project_path}" && detect_session_from_cwd &>/dev/null ); then
        die "Project path is inside an existing purifier sandbox. Refusing to nest."
    fi

    local session_id
    session_id="$(generate_session_id)"
    local sandbox_path="/tmp/purifier-${session_id}"

    log_info "Initializing sandbox for: ${BOLD}${project_path}${NC}"
    echo "  Session ID:  ${session_id}"
    echo "  Sandbox:     ${sandbox_path}"
    echo "  Timeout:     ${timeout}"
    echo ""

    # --- Step 1: Create mount point and mount tmpfs ---
    log_info "Mounting tmpfs sandbox..."
    sudo_mkdir "${sandbox_path}"
    defer "rmdir '${sandbox_path}' 2>/dev/null || true"
    defer "${SUDO} umount '${sandbox_path}' 2>/dev/null || true"
    sudo_mount -t tmpfs -o "${PURIFIER_MOUNT_OPTS}" tmpfs "${sandbox_path}"
    ${SUDO} chown "${USER}:$(id -gn)" "${sandbox_path}"
    log_info "  tmpfs mounted at ${sandbox_path}"

    # --- Step 2: Create sandbox directory structure ---
    mkdir -p "${sandbox_path}/project-ro" \
             "${sandbox_path}/upper" \
             "${sandbox_path}/work" \
             "${sandbox_path}/merged"

    # --- Step 3: Bind mount project read-only ---
    log_info "Binding project read-only..."
    defer "${SUDO} umount '${sandbox_path}/project-ro' 2>/dev/null || true"
    sudo_mount --bind "${project_path}" "${sandbox_path}/project-ro"
    sudo_mount -o remount,ro,bind "${sandbox_path}/project-ro"
    log_info "  Project bound at ${sandbox_path}/project-ro (read-only)"

    # --- Step 4: Setup overlayfs ---
    log_info "Setting up overlay filesystem..."
    if ! cat /proc/filesystems 2>/dev/null | grep -qw overlay; then
        log_info "  Loading overlay kernel module..."
        sudo_modprobe overlay || die "Failed to load overlay module. Try: sudo modprobe overlay"
    fi
    defer "${SUDO} umount '${sandbox_path}/merged' 2>/dev/null || true"
    sudo_mount -t overlay overlay \
        -o "lowerdir=${sandbox_path}/project-ro,upperdir=${sandbox_path}/upper,workdir=${sandbox_path}/work" \
        "${sandbox_path}/merged"
    log_info "  Overlay mounted at ${sandbox_path}/merged"

    # --- Step 5: Write session marker ---
    echo "${session_id}" > "${sandbox_path}/merged/.purifier-session"

    # --- Step 6: Save session metadata ---
    session_set "${session_id}" "session_id"   "${session_id}"
    session_set "${session_id}" "project_path" "${project_path}"
    session_set "${session_id}" "sandbox_path" "${sandbox_path}"
    session_set "${session_id}" "created_at"   "$(date -Iseconds)"

    # --- Step 7: Start systemd auto-wipe timer ---
    log_info "Starting auto-wipe timer (${timeout})..."
    local purifier_path
    purifier_path="$(realpath "${PURIFIER_ROOT}/purifier")"

    local unit_name="purifier-${session_id}"
    local timer_out
    timer_out="$(systemd-run --user --unit="${unit_name}" \
        --description="Purifier auto-wipe for ${session_id}" \
        --on-active="${timeout}" \
        --property=Type=oneshot \
        "${purifier_path}" end --session "${session_id}" --force 2>&1)" || {
        log_warn "Failed to start systemd timer: ${timer_out}"
        log_warn "Auto-wipe will NOT fire. Remember to run 'purifier end' manually."
        unit_name=""
    }
    if [[ -n "${unit_name}" ]]; then
        log_info "  Timer: ${timer_out%%$'\n'*}"
        session_set "${session_id}" "timer_unit" "${unit_name}"
    fi

    # --- Success: disarm cleanup traps and defer stack ---
    DEFER_STACK=""
    trap - EXIT

    # --- Done ---
    echo ""
    log_info "${GREEN}Sandbox is ready.${NC}"
    echo ""
    echo "  To work in the sandbox:"
    echo "    purifier exec                  # interactive shell"
    echo "    purifier exec <command>        # run a command"
    echo "    cd ${sandbox_path}/merged  # or work directly"
    echo ""
    echo "  To end the session:"
    echo "    purifier end                   # approval flow"
    echo "    purifier end --force           # wipe immediately"
    echo ""
    echo "  Auto-wipe in ${timeout} from now."
}
