# exec.sh - run commands inside sandbox

cmd_exec() {
    session_id=""; force_flag=0; parsed_rest=()
    parse_common_flags "$@"
    set -- "${parsed_rest[@]}"

    local sid
    sid="$(resolve_session "${session_id}")"

    local sandbox_path
    sandbox_path="$(session_get "${sid}" "sandbox_path")"
    [[ -z "${sandbox_path}" ]] && die "Session metadata missing sandbox_path"
    [[ ! -d "${sandbox_path}/merged" ]] && die "Sandbox merged directory not found. Session may have expired."

    local project_path
    project_path="$(session_get "${sid}" "project_path")"

    export PURIFIER_SESSION="${sid}"
    export PURIFIER_SANDBOX="${sandbox_path}"
    export PURIFIER_REAL_PROJECT="${project_path}"

    local cmd="${1:-}"
    if [[ -z "${cmd}" ]]; then
        log_info "Starting interactive shell in sandbox ${sid}"
        cd "${sandbox_path}/merged"
        if [[ -n "${PURIFIER_REAL_PROJECT}" ]]; then
            local rel
            rel="$(realpath --relative-to="${PURIFIER_REAL_PROJECT}" "${PWD}" 2>/dev/null)" || rel="."
            local target="${sandbox_path}/merged/${rel}"
            [[ -d "${target}" ]] && cd "${target}"
        fi
        export PS1="[purifier:\\w]\\$ "
        "${SHELL:-/bin/bash}" -i
    else
        cd "${sandbox_path}/merged"
        exec "$@"
    fi
}
