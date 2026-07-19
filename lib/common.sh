#!/usr/bin/env bash

if [[ -t 1 ]]; then
    _C_RED='\033[0;31m'
    _C_GREEN='\033[0;32m'
    _C_YELLOW='\033[1;33m'
    _C_BLUE='\033[0;34m'
    _C_RESET='\033[0m'
else
    _C_RED=''
    _C_GREEN=''
    _C_YELLOW=''
    _C_BLUE=''
    _C_RESET=''
fi

log_info() {
    printf '%b[INFO]%b %s\n' "${_C_BLUE}" "${_C_RESET}" "$*"
}

log_success() {
    printf '%b[ OK ]%b %s\n' "${_C_GREEN}" "${_C_RESET}" "$*"
}

log_warn() {
    printf '%b[WARN]%b %s\n' "${_C_YELLOW}" "${_C_RESET}" "$*" >&2
}

log_error() {
    printf '%b[FAIL]%b %s\n' "${_C_RED}" "${_C_RESET}" "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

require_root() {
    (( EUID == 0 )) || die "Скрипт должен быть запущен от root."
}

require_commands() {
    local missing=()
    local command_name

    for command_name in "$@"; do
        command -v "${command_name}" >/dev/null 2>&1 || missing+=("${command_name}")
    done

    ((${#missing[@]} == 0)) || die "Не найдены команды: ${missing[*]}"
}

quote_command() {
    printf ' %q' "$@"
    printf '\n'
}

