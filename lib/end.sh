# end.sh - session teardown, approval, promotion

cmd_end() {
    need_sudo

    session_id=""; force_flag=0; parsed_rest=()
    parse_common_flags "$@"
    set -- "${parsed_rest[@]}"

    local sid
    sid="$(resolve_session "${session_id}")"

    local sandbox_path project_path timer_unit created_at
    sandbox_path="$(session_get "${sid}" "sandbox_path")"
    project_path="$(session_get "${sid}" "project_path")"
    created_at="$(session_get "${sid}" "created_at")"
    timer_unit="purifier-${sid}"

    [[ -z "${sandbox_path}" ]] && die "Session metadata missing sandbox_path for ${sid}"
    [[ -z "${project_path}" ]] && die "Session metadata missing project_path for ${sid}"
    [[ ! -d "${sandbox_path}" ]] && die "Sandbox directory not found: ${sandbox_path}"

    echo ""
    log_info "Ending session ${BOLD}${sid}${NC}"
    echo "  Project: ${project_path}"
    echo "  Created: ${created_at}"
    echo ""

    # --- Step 1: Stop the auto-wipe timer ---
    log_info "Stopping auto-wipe timer..."
    if systemctl --user list-units --all "purifier-${sid}*" 2>/dev/null | grep -q .; then
        systemctl --user stop "${timer_unit}.timer" 2>/dev/null || true
        systemctl --user stop "${timer_unit}.service" 2>/dev/null || true
        systemctl --user reset-failed "${timer_unit}.timer" 2>/dev/null || true
        systemctl --user reset-failed "${timer_unit}.service" 2>/dev/null || true
    fi

    # --- Step 2: Approval flow (skip if --force) ---
    local promote=0
    if [[ "${force_flag}" -eq 1 ]]; then
        log_warn "Force mode -- changes will NOT be promoted."
        echo ""
    elif approval_flow "${sid}" "${sandbox_path}" "${project_path}"; then
        promote=1
    fi

    # --- Step 3: Promote changes if approved ---
    if [[ "${promote}" -eq 1 ]]; then
        promote_changes "${sid}" "${sandbox_path}" "${project_path}"
    fi

    # --- Step 4: Unmount all layers ---
    log_info "Unmounting sandbox layers..."
    local umount_errors=0
    local umount_flags=""
    [[ "${force_flag}" -eq 1 ]] && umount_flags="-l"

    if mountpoint -q "${sandbox_path}/merged" 2>/dev/null; then
        sudo_umount ${umount_flags} "${sandbox_path}/merged" || { log_warn "  Failed to unmount overlay"; umount_errors=1; }
    fi

    if mountpoint -q "${sandbox_path}/project-ro" 2>/dev/null; then
        sudo_umount ${umount_flags} "${sandbox_path}/project-ro" || { log_warn "  Failed to unmount project bind"; umount_errors=1; }
    fi

    if mountpoint -q "${sandbox_path}" 2>/dev/null; then
        sudo_umount ${umount_flags} "${sandbox_path}" || { log_warn "  Failed to unmount tmpfs"; umount_errors=1; }
    fi

    # --- Step 5: Cleanup session data ---
    log_info "Cleaning up session data..."
    rm -rf "${sandbox_path}" 2>/dev/null || true
    session_delete "${sid}"

    echo ""
    if [[ "${umount_errors}" -eq 0 ]]; then
        log_info "${GREEN}Session ${sid} fully cleaned up.${NC}"
    else
        log_warn "Session ${sid} cleaned with some unmount errors."
        log_warn "Manual check may be needed: ${sandbox_path}"
    fi
}

# --- Approval Flow ---
# Returns: 0 (promote) or 1 (discard)
approval_flow() {
    local sid="$1" sandbox_path="$2" project_path="$3"

    local sandbox_merged="${sandbox_path}/merged"
    if ! mountpoint -q "${sandbox_merged}" 2>/dev/null; then
        log_warn "Overlay already unmounted; trying to detect changes from upper dir..."
        if [[ -d "${sandbox_path}/upper" ]] && [[ -n "$(ls -A "${sandbox_path}/upper" 2>/dev/null)" ]]; then
            sandbox_merged="${sandbox_path}/upper"
        else
            log_info "No changes detected. Nothing to promote."
            return 1
        fi
    fi

    # Generate diff
    local diff_output
    diff_output="$(generate_diff "${sandbox_merged}" "${project_path}")"

    if [[ -z "${diff_output}" ]]; then
        log_info "No differences found between sandbox and project."
        return 1
    fi

    echo ""
    log_info "${BOLD}Changes detected in sandbox:${NC}"

    # Show full diff with pager
    if [[ -n "${diff_output}" ]]; then
        local pager="${PAGER:-less}"
        if find_on_path "${pager}" &>/dev/null; then
            echo "${diff_output}" | "${pager}"
        else
            echo "${diff_output}"
        fi
    fi

    echo ""

    # Ask for approval
    local answer=""
    while [[ ! "${answer}" =~ ^[yYnNsS]$ ]]; do
        read -r -p "Promote these changes to the real project? [y/n] " answer
    done

    if [[ "${answer}" =~ ^[yY]$ ]]; then
        return 0
    else
        log_info "Changes discarded. Sandbox will be wiped."
        return 1
    fi
}

# --- Diff Generation ---
generate_diff() {
    local merged="$1" project="$2"

    if [[ -d "${project}/.git" ]]; then
        GIT_DIR="${project}/.git" git --work-tree="${merged}" diff --no-color 2>/dev/null || true
        local untracked
        untracked="$(GIT_DIR="${project}/.git" git --work-tree="${merged}" ls-files --others --exclude-standard 2>/dev/null)" || true
        if [[ -n "${untracked}" ]]; then
            echo "--- untracked files ---"
            echo "${untracked}"
        fi
    else
        diff --unified=3 -rN --no-dereference \
            "${project}" "${merged}" \
            --exclude=.purifier-session \
            2>/dev/null || true
    fi
}

# --- Promote Changes ---
promote_changes() {
    local sid="$1" sandbox_path="$2" project_path="$3"
    local merged="${sandbox_path}/merged"

    # Ensure target exists
    [[ ! -d "${project_path}" ]] && die "Project path vanished: ${project_path}"

    log_info "Promoting changes to real project..."
    echo "  Source: ${merged}"
    echo "  Target: ${project_path}"
    echo ""

    # Backup conflicting files (outside sandbox — it's about to be wiped)
    local backup_dir="/tmp/purifier-backup-${sid}-$(date +%s)"
    mkdir -p "${backup_dir}"

    if mountpoint -q "${merged}" 2>/dev/null; then
        # Overlay is still mounted, use rsync from merged
        rsync -a --delete \
            --exclude=.git \
            --exclude=.purifier-session \
            --backup --backup-dir="${backup_dir}" \
            "${merged}/" "${project_path}/" 2>&1 || {
            log_error "rsync failed during promotion"
            return 1
        }
    else
        # Overlay unmounted, try from upper dir
        log_warn "Overlay already unmounted, promoting from upper/ (deletions not captured)"
        if [[ -d "${sandbox_path}/upper" ]]; then
            rsync -a \
                --exclude=.git \
                --exclude=.purifier-session \
                "${sandbox_path}/upper/" "${project_path}/" 2>&1 || {
                log_error "rsync from upper/ failed"
                return 1
            }
        fi
    fi

    log_info "${GREEN}Changes promoted successfully.${NC}"
    if [[ -d "${backup_dir}" ]] && [[ -n "$(ls -A "${backup_dir}" 2>/dev/null)" ]]; then
        log_info "Backups of overwritten files: ${backup_dir}"
    else
        rm -rf "${backup_dir}" 2>/dev/null || true
    fi
}

# --- List Sessions ---
cmd_list() {
    local count=0
    if [[ ! -d "${PURIFIER_SESSION_DIR}" ]]; then
        echo "No sessions found."
        return 0
    fi

    for sid_dir in "${PURIFIER_SESSION_DIR}"/*/; do
        [[ -d "${sid_dir}" ]] || continue
        local sid
        sid="$(basename "${sid_dir}")"
        local project sandbox created
        project="$(cat "${sid_dir}project_path" 2>/dev/null || echo "?")"
        sandbox="$(cat "${sid_dir}sandbox_path" 2>/dev/null || echo "?")"
        created="$(cat "${sid_dir}created_at" 2>/dev/null || echo "?")"

        local status
        if mountpoint -q "${sandbox}/merged" 2>/dev/null; then
            status="${GREEN}active${NC}"
        elif [[ -d "${sandbox}" ]]; then
            status="${YELLOW}stale${NC}"
        else
            status="${RED}gone${NC}"
        fi

        printf "  %-12s %-20s %-10s %s\n" "${sid}" "${project##*/}" "${created%%T*}" "${status}"
        count=$((count + 1))
    done

    if [[ "${count}" -eq 0 ]]; then
        echo "No sessions found."
    else
        echo ""
        echo "${count} session(s)"
    fi
}

# --- Session Status ---
cmd_status() {
    local sid
    sid="$(resolve_session "")" 2>/dev/null || {
        # If no default session, list all
        cmd_list
        return
    }

    local sandbox_path project_path created_at timer_unit
    sandbox_path="$(session_get "${sid}" "sandbox_path")"
    project_path="$(session_get "${sid}" "project_path")"
    created_at="$(session_get "${sid}" "created_at")"

    echo "Session:    ${sid}"
    echo "Project:    ${project_path}"
    echo "Created:    ${created_at}"
    echo "Sandbox:    ${sandbox_path}"

    if [[ -d "${sandbox_path}" ]]; then
        echo "Directory:  exists"

        local mounted="no"
        mountpoint -q "${sandbox_path}/merged" 2>/dev/null && mounted="overlay"
        mountpoint -q "${sandbox_path}/project-ro" 2>/dev/null && mounted="${mounted}+bind"
        echo "Mounted:    ${mounted}"

        local timer_active="no"
        systemctl --user is-active "purifier-${sid}.timer" &>/dev/null && timer_active="yes"
        echo "Timer:      ${timer_active}"

        local merged="${sandbox_path}/merged"
        if [[ -d "${merged}" ]]; then
            local changes
            changes="$(generate_diff "${merged}" "${project_path}" | head -20)"
            if [[ -n "${changes}" ]]; then
                echo "Changes:    detected"
            else
                echo "Changes:    none"
            fi
        fi
    else
        echo "Directory:  ${RED}missing${NC}"
    fi
}

# --- Setup Sudo ---
cmd_setup_sudo() {
    local sudoers_file="/etc/sudoers.d/purifier"
    local mount_bin umount_bin modprobe_bin
    mount_bin="$(find_on_path mount)"
    umount_bin="$(find_on_path umount)"
    modprobe_bin="$(find_on_path modprobe)"

    if [[ -f "${sudoers_file}" ]]; then
        log_warn "Sudoers file already exists: ${sudoers_file}"
        echo -n "Overwrite? [y/N] "
        local ans; read -r ans
        [[ "${ans}" =~ ^[yY] ]] || { echo "Aborted."; return 1; }
    fi

    echo ""
    echo "Setting up passwordless sudo for purifier mount operations..."
    echo ""
    echo "The following entry will be added to ${sudoers_file}:"
    echo "  ${USER} ALL=(ALL) NOPASSWD: ${mount_bin}, ${umount_bin}, ${modprobe_bin}"
    echo ""
    echo "This allows purifier to mount tmpfs, bind mounts, and overlayfs"
    echo "without requiring a password each time."
    echo ""
    echo "You will be prompted for your sudo password to create this file."
    echo ""

    local content
    content="${USER} ALL=(ALL) NOPASSWD: ${mount_bin}, ${umount_bin}"
    if [[ -n "${modprobe_bin}" ]]; then
        content="${content}, ${modprobe_bin}"
    fi

    echo "${content}" | ${SUDO} tee "${sudoers_file}" >/dev/null
    ${SUDO} chmod 440 "${sudoers_file}"

    echo ""
    log_info "Sudo configured. You can now use purifier without password prompts for mount operations."
}
