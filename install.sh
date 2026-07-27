#!/bin/bash

# ──────────────────────────────────────────────────────────────────────────────
# Copyright (C) 2026 @dreamelite96
# SPDX-License-Identifier: GPL-3.0-or-later
#
# This file is part of "pbgui-docker".
# https://github.com/dreamelite96/pbgui-docker
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# ──────────────────────────────────────────────────────────────────────────────

# install.sh — One-command install: clone + setup + build + launch for PBGui Docker.
#
# Designed to be run directly from GitHub — no prior clone needed:
#   sudo bash <(curl -fsSL https://raw.githubusercontent.com/dreamelite96/pbgui-docker/main/install.sh)
#
# Can also be run locally from an already-cloned repository:
#   sudo ./install.sh
#
# Optional arguments:
#   [/base/dir]          Base directory where pbgui-docker/ will be created
#   --non-interactive    Skip all prompts; use defaults (for CI / scripting)

set -euo pipefail

# ─── Cleanup trap ─────────────────────────────────────────────────────────────
# Fires on any unhandled error (ERR) or explicit exit (EXIT with non-zero code).
# Reminds the user to inspect the state manually; does not attempt auto-rollback
# because partially-created resources (ZFS datasets, .env files, …) are safer
# left in place for the operator to review than silently removed.
_trap_cleanup() {
    local code=$?
    [ $code -eq 0 ] && return
    echo ""
    warn "Installation interrupted (exit code ${code})."
    warn "Review the output above, fix the issue, and re-run the script."
    warn "Partially created files or directories are left intact for inspection."
    echo ""
}
trap _trap_cleanup EXIT

# ─── Root / sudo check ────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo ""
    echo "  [ERR] This script must be run as root or with sudo."
    echo "        sudo ./install.sh"
    echo "        sudo bash <(curl -fsSL <url>)"
    echo ""
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# COLOURS & HELPERS
# ══════════════════════════════════════════════════════════════════════════════

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'
DIM='\033[2m'; RESET='\033[0m'

# Consistent line-prefix icons — all left-padded to 2 spaces.
# Format:  <2sp><icon><1sp><message>
success() { echo -e "  ${GREEN}✓${RESET} $*"; }
info()    { echo -e "  ${CYAN}·${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}!${RESET} $*"; }
error()   { echo -e "  ${RED}✗${RESET} $*" >&2; exit 1; }

# Single divider style used everywhere
divider()      { echo -e "${DIM}  ──────────────────────────────────────────────────────${RESET}"; }
mini_divider() { echo -e "${DIM}  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─${RESET}"; }

# Interactive yes/no prompt
# Usage: confirm "Question?" [default: y|n]
confirm() {
    local msg="$1" default="${2:-n}" hint
    [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
    echo -en "  ${CYAN}?${RESET} ${msg} [${hint}]: "
    read -rp "" reply
    echo ""
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[yY]$ ]]
}

mini_confirm() {
    local msg="$1" default="${2:-n}" hint
    [[ "$default" == "y" ]] && hint="Y/n" || hint="y/N"
    echo -en "  ${CYAN}?${RESET} ${msg} [${hint}]: "
    read -rp "" reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[yY]$ ]]
}

# Generic labelled prompt — prints label + dim hint, reads into named var
# Usage: prompt_input VARNAME "Label" "default value" [secret]
prompt_input() {
    local __var="$1" label="$2" default="$3" secret="${4:-}"
    echo -e "  ${CYAN}+${RESET} ${label}${DIM}${default}${RESET}:"
    if [[ "$secret" == "secret" ]]; then
        read -rsp "    ❯ " __val; echo ""
    else
        read -rp  "    ❯ " __val
    fi
    printf -v "$__var" '%s' "${__val:-$default}"
    echo ""
}

pause() {
    echo ""
    echo -en "  ${DIM}Press ${RESET}${BOLD}Enter${RESET}${DIM} to continue or ${RESET}${BOLD}Ctrl+C${RESET}${DIM} to abort...${RESET}  "
    read -r
}

# Step banner — auto-increments STEP counter
STEP=0
TOTAL_STEPS=9
nextstep() {
    STEP=$((STEP + 1))
    echo ""
    echo ""
    echo -e "${BOLD}${BLUE}  [${STEP}/${TOTAL_STEPS}]  ${1}${RESET}"
    divider
}

# Sets or replaces a KEY=VALUE entry in the .env file.
env_set() {
    local key="$1" val="$2"
    if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
}

# ─── Project constants ────────────────────────────────────────────────────────
REPO_URL="https://github.com/dreamelite96/pbgui-docker.git"
REPO_DIRNAME="pbgui-docker"

# Default port values — overridden later by .env if present.
WEBUI_PORT="8000"
CONTAINER="pbgui"

# Host user that will own and manage the Docker setup after installation.
# UID/GID are read after user creation/selection and written to .env so that
# docker compose can pass them to the Dockerfile and set the container process
# user, keeping host ownership and container runtime in sync.
DOCKER_USER="root"
DOCKER_UID=1000
DOCKER_GID=1000
DOCKER_USER_CREATED=false
DOCKER_GROUP_ADDED=false

# ─── Script origin detection ──────────────────────────────────────────────────
_src="${BASH_SOURCE[0]:-}"
if [[ -n "$_src" ]] && \
   [[ "$_src" != "/dev/stdin" ]] && \
   [[ "$_src" != "/dev/fd/"* ]] && \
   [[ "$_src" != "/proc/"* ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$_src")" && pwd)"
else
    SCRIPT_DIR=""
fi
unset _src

IS_CURL_INSTALL=true
REPO_DIR=""
if [[ -n "$SCRIPT_DIR" ]] && \
   [ -f "${SCRIPT_DIR}/docker-compose.yml" ] && \
   [ -f "${SCRIPT_DIR}/Dockerfile" ]; then
    IS_CURL_INSTALL=false
    REPO_DIR="$SCRIPT_DIR"
fi

# ─── Argument parsing ─────────────────────────────────────────────────────────
NON_INTERACTIVE=false
PRESET_PATH=""

for arg in "$@"; do
    case "$arg" in
        --non-interactive) NON_INTERACTIVE=true ;;
        --*)               warn "Unknown flag: $arg" ;;
        *)                 PRESET_PATH="$arg" ;;
    esac
done

# ─── Utility: environment & host IP ──────────────────────────────────────────
detect_environment() {
    if [ -f /etc/truenas ] || grep -qi "truenas\|freenas" /etc/os-release 2>/dev/null; then
        echo "TrueNAS"
    else
        echo "Linux"
    fi
}

detect_host_ip() {
    local ip=""
    ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1) || true
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    echo "${ip:-127.0.0.1}"
}

# ─── Input sanitisation ───────────────────────────────────────────────────────

# Escapes backslashes and double-quotes so the value is safe inside a
# double-quoted string literal (JSON, TOML, or any similar format).
sanitize_string() {
    local val="$1"
    val="${val//\\/\\\\}"   # \ → \\
    val="${val//\"/\\\"}"   # " → \"
    echo "$val"
}

# ══════════════════════════════════════════════════════════════════════════════
# BANNER
# ══════════════════════════════════════════════════════════════════════════════

clear
echo -e "${BOLD}${CYAN}"
echo -e "  ██████╗ ██████╗  ██████╗ ██╗   ██╗██╗"
echo -e "  ██╔══██╗██╔══██╗██╔════╝ ██║   ██║██║"
echo -e "  ██████╔╝██████╔╝██║  ███╗██║   ██║██║  ████████╗"
echo -e "  ██╔═══╝ ██╔══██╗██║   ██║██║   ██║██║  ╚═══════╝"
echo -e "  ██║     ██████╔╝╚██████╔╝╚██████╔╝██║"
echo -e "  ╚═╝     ╚═════╝  ╚═════╝  ╚═════╝ ╚═╝"
echo -e "  ██████╗  ██████╗  ██████╗ ██╗  ██╗███████╗██████╗ "
echo -e "  ██╔══██╗██╔═══██╗██╔════╝ ██║ ██╔╝██╔════╝██╔══██╗"
echo -e "  ██║  ██║██║   ██║██║      █████╔╝ █████╗  ██████╔╝"
echo -e "  ██║  ██║██║   ██║██║      ██╔═██╗ ██╔══╝  ██╔══██╗"
echo -e "  ██████╔╝╚██████╔╝╚██████╗ ██║  ██╗███████╗██║  ██║"
echo -e "  ╚═════╝  ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝${RESET}"
echo ""
echo -e "  ${DIM}One-Command Install — PBGui-Docker by @dreamelite96${RESET}"
echo ""
divider
echo ""
echo -e "  ${BOLD}This script will:${RESET}"
echo -e "  ${DIM}1.${RESET}  Check prerequisites    ${DIM}docker · docker compose · git${RESET}"
echo -e "  ${DIM}2.${RESET}  Set up host user       ${DIM}dedicated user · existing · root${RESET}"
echo -e "  ${DIM}3.${RESET}  Detect environment     ${DIM}TrueNAS or Linux${RESET}"
echo -e "  ${DIM}4.${RESET}  Choose install path    ${DIM}base dir → ${REPO_DIRNAME}/ created inside${RESET}"
echo -e "  ${DIM}5.${RESET}  Provision storage      ${DIM}ZFS dataset on TrueNAS · plain dir on Linux${RESET}"
echo -e "  ${DIM}6.${RESET}  Clone repository       ${DIM}from GitHub${RESET}"
echo -e "  ${DIM}7.${RESET}  Write configuration    ${DIM}userdata dirs · api-keys.json · secrets.toml${RESET}"
echo -e "  ${DIM}8.${RESET}  Build & launch         ${DIM}docker compose up -d --build${RESET}"
echo -e "  ${DIM}9.${RESET}  Verify health          ${DIM}polls the built-in healthcheck${RESET}"
echo ""

if ! $NON_INTERACTIVE; then
    if ! confirm "Ready to proceed?" "y"; then
        warn "Aborted by user."
        echo ""
        exit 0
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — Prerequisites
# ══════════════════════════════════════════════════════════════════════════════

nextstep "Prerequisites"

MISSING=()
command -v docker &>/dev/null || MISSING+=("docker")
command -v git    &>/dev/null || MISSING+=("git")
[ ${#MISSING[@]} -gt 0 ] && error "Missing required tools: ${MISSING[*]}  —  install them and re-run."

if ! docker compose version &>/dev/null 2>&1; then
    error "'docker compose' (v2 plugin) not found.  Install Docker Compose v2+ and retry."
fi

if ! docker info &>/dev/null 2>&1; then
    error "Docker daemon is not running or not reachable.  Start Docker and re-run."
fi

success "docker           $(docker --version  | grep -oP '\d+\.\d+\.\d+' | head -1)"
success "docker compose   $(docker compose version | grep -oP '\d+\.\d+\.\d+' | head -1)"
success "git              $(git --version | awk '{print $3}')"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — Host User Setup
# ══════════════════════════════════════════════════════════════════════════════

nextstep "Host User Setup"

if ! $NON_INTERACTIVE; then

    echo -e "  ${DIM}Docker commands (docker compose up, docker logs, ...) are run on the host${RESET}"
    echo -e "  ${DIM}by an OS user that belongs to the docker group.${RESET}"
    echo ""
    echo -e "  ${DIM}The user you choose here will own the repository files and its UID/GID${RESET}"
    echo -e "  ${DIM}will be mapped inside the container to prevent permission errors.${RESET}"
    echo ""
    echo -e "  ${YELLOW}!${RESET} ${BOLD}Security Sandbox:${RESET}"
    echo -e "    ${DIM}The process inside Docker ALWAYS runs as a non-root user.${RESET}"
    echo -e "    ${DIM}Even if you select ${RESET}root${DIM} (3), the container will use ID 1000 for safety.${RESET}"
    echo ""

    if [ "$(detect_environment)" = "TrueNAS" ]; then
        warn "TrueNAS detected — create the user from the TrueNAS UI first,"
        warn "then select option 2 (existing user) below."
        echo ""
    fi

    echo -e "  ${BOLD}Who should run Docker commands on this host?${RESET}"
    echo ""
    echo -e "    ${DIM}1)${RESET}  Create a new ${CYAN}pbgui${RESET} user  ${DIM}(recommended)${RESET}"
    echo -e "    ${DIM}2)${RESET}  Use an existing user"
    echo -e "    ${DIM}3)${RESET}  Continue as ${YELLOW}root${RESET}         ${DIM}(not recommended)${RESET}"
    echo ""
    echo -en "  ${CYAN}?${RESET} Your choice ${DIM}[1]${RESET}: "
    read -r _choice
    echo ""
    _choice="${_choice:-1}"

    case "$_choice" in
        1)
            if id "pbgui" &>/dev/null 2>&1; then
                warn "User 'pbgui' already exists — skipping creation."
            else
                useradd -m -s /bin/bash pbgui
                success "User 'pbgui' created."
                DOCKER_USER_CREATED=true
            fi
            DOCKER_USER="pbgui"
            if groups pbgui | grep -qw docker; then
                success "User 'pbgui' is already in the docker group."
            else
                usermod -aG docker pbgui
                DOCKER_GROUP_ADDED=true
                success "User 'pbgui' added to the docker group."
            fi
            ;;
        2)
            while true; do
                echo -en "  ${CYAN}+${RESET} Username: "
                read -r _uname
                echo ""
                if id "$_uname" &>/dev/null 2>&1; then
                    DOCKER_USER="$_uname"
                    break
                fi
                warn "User '${_uname}' not found — try again."
            done
            unset _uname

            if groups "$DOCKER_USER" | grep -qw docker; then
                success "User '${DOCKER_USER}' is already in the docker group."
            else
                warn "User '${DOCKER_USER}' is not in the docker group."
                if confirm "Add '${DOCKER_USER}' to the docker group?" "y"; then
                    usermod -aG docker "$DOCKER_USER"
                    DOCKER_GROUP_ADDED=true
                    success "User '${DOCKER_USER}' added to the docker group."
                else
                    error "User '${DOCKER_USER}' needs docker group membership to run Docker commands."
                fi
            fi
            ;;
        3)
            DOCKER_USER="root"
            warn "Continuing as root."
            ;;
        *)
            warn "Invalid choice — defaulting to root."
            DOCKER_USER="root"
            ;;
    esac
    unset _choice

else
    info "Non-interactive mode — using root as Docker user."
fi

# Read the UID/GID of the chosen user so they can be passed to docker compose
# (container process user) and to the Dockerfile (container user creation).
# For root, fall back to 1000:1000 so the container does not run as root.
if [ "$DOCKER_USER" = "root" ]; then
    DOCKER_UID=1000
    DOCKER_GID=1000
else
    DOCKER_UID=$(id -u "$DOCKER_USER")
    DOCKER_GID=$(id -g "$DOCKER_USER")
fi

echo ""
info "Docker user      ${CYAN}${DOCKER_USER}${RESET}  ${DIM}(uid=${DOCKER_UID}  gid=${DOCKER_GID})${RESET}"
if $DOCKER_USER_CREATED || $DOCKER_GROUP_ADDED; then
    warn "Group membership takes effect after '${DOCKER_USER}' logs in for the first time."
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Environment Detection
# ══════════════════════════════════════════════════════════════════════════════

nextstep "Environment Detection"

ENV_TYPE=$(detect_environment)
MIDCLT_AVAILABLE=false

info "Detected OS      ${CYAN}${ENV_TYPE}${RESET}"

if [ "$ENV_TYPE" = "TrueNAS" ]; then
    TRUENAS_VER=$(grep -oP '(?<=VERSION=")[^"]+' /etc/os-release 2>/dev/null || echo "unknown")
    info "TrueNAS Version  ${CYAN}${TRUENAS_VER}${RESET}"
    if command -v midclt &>/dev/null; then
        info "midclt (API)     ${GREEN}available${RESET}  ${DIM}— ZFS dataset auto-creation supported${RESET}"
        MIDCLT_AVAILABLE=true
    else
        info "midclt (API)     ${RED}not found${RESET}  ${DIM}— will fall back to zfs CLI${RESET}"
    fi
fi

if $IS_CURL_INSTALL; then
    info "Install mode     ${CYAN}remote${RESET}  ${DIM}— repository will be cloned${RESET}"
else
    info "Install mode     ${CYAN}local${RESET}      ${DIM}— repository already present${RESET}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Install Location
# ══════════════════════════════════════════════════════════════════════════════

nextstep "Install Location"

if $IS_CURL_INSTALL; then
    if [ "$ENV_TYPE" = "TrueNAS" ] && [ -z "$PRESET_PATH" ]; then
        DEFAULT_BASE="/mnt/tank/docker"
    else
        DEFAULT_BASE="${PRESET_PATH:-/opt/docker}"
    fi

    if $NON_INTERACTIVE; then
        INSTALL_BASE="$DEFAULT_BASE"
    else
        echo -e "  ${DIM}The script will clone ${REPO_DIRNAME}/ inside the chosen directory.${RESET}"
        echo ""
        prompt_input INSTALL_BASE "Docker apps directory" " [$DEFAULT_BASE]"
    fi

    REPO_DIR="${INSTALL_BASE}/${REPO_DIRNAME}"

else
    REPO_DIR="$SCRIPT_DIR"
    INSTALL_BASE="$(dirname "$REPO_DIR")"
    info "Repository already present — no clone needed."
fi

USERDATA_PATH="${REPO_DIR}/userdata"

echo ""
info "Install base     ${CYAN}${INSTALL_BASE}${RESET}"
info "Repository       ${CYAN}${REPO_DIR}${RESET}"
info "Userdata         ${CYAN}${USERDATA_PATH}${RESET}"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — Storage Provisioning
# ══════════════════════════════════════════════════════════════════════════════

nextstep "Storage Provisioning"

DATASET_CREATED=false
ZFS_DATASET=""

if ! $IS_CURL_INSTALL; then
    success "Repository directory already exists — skipping provisioning."

elif [ "$ENV_TYPE" = "TrueNAS" ]; then

    if [ ! -d "$REPO_DIR" ]; then
        if [[ "$REPO_DIR" == /mnt/* ]]; then
            ZFS_DATASET="${REPO_DIR#/mnt/}"
        else
            warn "Path does not start with /mnt/ — cannot auto-derive ZFS dataset name."
            ZFS_DATASET="${REPO_DIR#/}"
        fi

        info "Target path      ${CYAN}${REPO_DIR}${RESET}  ${DIM}(does not exist yet)${RESET}"
        info "ZFS dataset      ${CYAN}${ZFS_DATASET}${RESET}"
        info "Settings         ${DIM}compression=lz4  ·  atime=off  ·  chmod 755 root:root${RESET}"
        echo ""

        if $NON_INTERACTIVE || confirm "Create this ZFS dataset automatically?" "y"; then

            if $MIDCLT_AVAILABLE; then
                _current=""
                IFS='/' read -ra _parts <<< "$ZFS_DATASET"
                for _part in "${_parts[@]}"; do
                    [ -z "$_part" ] && continue
                    if [ -z "$_current" ]; then
                        _current="$_part"
                        continue
                    fi
                    _current="${_current}/${_part}"
                    if zfs list "$_current" &>/dev/null 2>&1; then
                        warn "Dataset already exists  ${_current}"
                    else
                        if midclt call pool.dataset.create \
                            "{\"name\": \"${_current}\", \"type\": \"FILESYSTEM\", \"atime\": \"OFF\", \"compression\": \"LZ4\"}" \
                            >/dev/null 2>&1; then
                            success "Dataset created (midclt)   ${_current}"
                        else
                            warn "midclt failed for ${_current} — falling back to zfs create"
                            command -v zfs &>/dev/null || error "'zfs' not found in PATH — cannot create dataset ${_current}."
                            zfs create -p "$_current"
                            success "Dataset created (zfs)      ${_current}"
                        fi
                    fi
                done
            else
                command -v zfs &>/dev/null || error "'zfs' not found in PATH — install the ZFS utilities and re-run."
                zfs create -p "$ZFS_DATASET"
                success "Dataset created (zfs)    ${ZFS_DATASET}"
            fi

            chown root:root "$REPO_DIR"
            chmod 755 "$REPO_DIR"
            success "Permissions applied      ${DIM}755 root:root${RESET}"
            DATASET_CREATED=true

        else
            error "'${REPO_DIR}' does not exist and creation was declined.  Create the dataset manually and re-run."
        fi

    else
        if mountpoint -q "$REPO_DIR" 2>/dev/null; then
            success "Mount point confirmed    ${REPO_DIR}"
        else
            warn "Directory exists but is not a registered mount point  ${DIM}${REPO_DIR}${RESET}"
        fi
    fi

else
    if [ -d "$REPO_DIR" ]; then
        warn "Directory already exists — skipping creation  ${DIM}${REPO_DIR}${RESET}"
    else
        mkdir -p "$REPO_DIR"
        success "Directory created        ${REPO_DIR}"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — Repository
# ══════════════════════════════════════════════════════════════════════════════

nextstep "Repository"

if ! $IS_CURL_INSTALL; then
    success "Using existing repository    ${DIM}${REPO_DIR}${RESET}"

elif [ -d "${REPO_DIR}/.git" ]; then
    warn "Repository already cloned — pulling latest changes."
    if git -C "$REPO_DIR" pull --ff-only 2>/dev/null; then
        echo ""
        success "Repository updated."
    else
        echo ""
        warn "Fast-forward pull failed — local changes may be present."
        warn "The existing repository will be used as-is."
        warn "Run 'git -C ${REPO_DIR} pull' manually to resolve."
    fi

else
    info "Source    ${CYAN}${REPO_URL}${RESET}"
    info "Target    ${CYAN}${REPO_DIR}${RESET}"
    echo ""
    git clone "$REPO_URL" "$REPO_DIR"
    echo ""
    success "Repository cloned."
fi

# ─── Load .env overrides ──────────────────────────────────────────────────────
# If a .env file exists in the repository root, extract only the specific
# variables needed for display (ports, container name).
# Parsing is done with grep/cut rather than sourcing the file as shell code,
# which would execute arbitrary commands as root.
ENV_FILE="${REPO_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
    _env_webui=$(grep -E '^PBGUI_WEBUI_PORT='     "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    _env_ctr=$(grep   -E '^PBGUI_CONTAINER_NAME='  "$ENV_FILE" | tail -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    WEBUI_PORT="${_env_webui:-$WEBUI_PORT}"
    CONTAINER="${_env_ctr:-$CONTAINER}"
    unset _env_webui _env_ctr
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — Files & Configuration
# ══════════════════════════════════════════════════════════════════════════════

nextstep "Files & Configuration"

# Subdirectory layout:
#   pbgui_data/                    — PBGui runtime state (bots, UI preferences, SQLite db)
#   pbgui_data/auth/               — FastAPI authentication credentials (secrets.toml)
#   historical_data/               — OHLCV market data, shared across tools
#   rclone/                        — rclone.conf cloud bucket credentials
#   pb7/configs/                   — Passivbot v7 live trading configs
#   pb7/backtests/                 — Passivbot v7 backtest result archives
#   pb7/optimize_results/          — Passivbot v7 optimisation outputs
#   pb7/optimize_results_analysis/ — Passivbot v7 optimisation reports
#   pb7/caches/                    — Passivbot v7 market data cache
#   pb8/configs/                   — Passivbot v8 live trading configs
#   pb8/backtests/                 — Passivbot v8 backtest result archives
#   pb8/optimize_results/          — Passivbot v8 optimisation outputs
#   pb8/caches/                    — Passivbot v8 market data cache

SUBDIRS=(
    pbgui_data
    pbgui_data/auth
    historical_data
    rclone
    pb7/configs
    pb7/backtests
    pb7/optimize_results
    pb7/optimize_results_analysis
    pb7/caches
    pb8/configs
    pb8/backtests
    pb8/optimize_results
    pb8/caches
)

echo -e "  ${BOLD}Userdata directories${RESET}"
echo ""
for dir in "${SUBDIRS[@]}"; do
    target="${USERDATA_PATH}/${dir}"
    if [ -d "$target" ]; then
        echo -e "    ${DIM}· ${dir}  (already exists)${RESET}"
    else
        mkdir -p "$target"
        echo -e "    ${GREEN}✓${RESET} ${dir}"
    fi
done
echo ""

# Apply 755 to directories; restrict auth directory to 700.
find "$USERDATA_PATH" -type d -exec chmod 755 {} +
chmod 700 "${USERDATA_PATH}/pbgui_data/auth" 2>/dev/null || true
success "Permissions applied  ${DIM}755 (directories) / 700 (auth)${RESET}"

# ── .env ──────────────────────────────────────────────────────────────────────

echo ""
mini_divider
echo ""
echo -e "  ${BOLD}Environment file (.env)${RESET}"
echo ""

if [ -f "$ENV_FILE" ]; then
    info ".env already present — skipping  ${DIM}(customisations preserved)${RESET}"
else
    cp "${REPO_DIR}/.env.example" "$ENV_FILE"
    success ".env created from .env.example"
    info "Edit ${CYAN}${ENV_FILE}${RESET} to customise ports, resource limits, and image name."
fi

# Write UID/GID to .env so docker compose can pass them as build args to the
# Dockerfile and use them in the 'user:' field to run the container process
# as the same account that owns the files on the host.
# Write UID/GID to .env so docker compose can pass them as build args to the
# Dockerfile and use them in the 'user:' field to run the container process
# as the same account that owns the files on the host.
env_set PBGUI_UID "$DOCKER_UID"
env_set PBGUI_GID "$DOCKER_GID"
success "UID/GID written to .env  ${DIM}(${DOCKER_UID}:${DOCKER_GID})${RESET}"

# ── Component Git Version Selection ───────────────────────────────────────────
# Downloads are strictly enforced from official GitHub repositories:
#   PBGui:     https://github.com/msei99/pbgui.git
#   Passivbot: https://github.com/enarjord/passivbot.git

VERSIONS_FILE="${REPO_DIR}/versions.env"
DEFAULT_PBGUI_COMMIT="37942d20e4670e2c97c5477ec0af413a6e94a294"
DEFAULT_PB7_COMMIT="fc6b9e016e04a3723bb5fe8847f1500049fa982c"
DEFAULT_PB8_COMMIT="a0897f83932db5e6888c1c96f8f1c668d452013f"

if [ -f "$VERSIONS_FILE" ]; then
    _v_pbgui=$(grep -E '^PBGUI_COMMIT=' "$VERSIONS_FILE" | cut -d= -f2- | tr -d '[:space:]')
    _v_pb7=$(grep -E '^PB7_COMMIT=' "$VERSIONS_FILE" | cut -d= -f2- | tr -d '[:space:]')
    _v_pb8=$(grep -E '^PB8_COMMIT=' "$VERSIONS_FILE" | cut -d= -f2- | tr -d '[:space:]')
    DEFAULT_PBGUI_COMMIT="${_v_pbgui:-$DEFAULT_PBGUI_COMMIT}"
    DEFAULT_PB7_COMMIT="${_v_pb7:-$DEFAULT_PB7_COMMIT}"
    DEFAULT_PB8_COMMIT="${_v_pb8:-$DEFAULT_PB8_COMMIT}"
fi

SEL_PBGUI_COMMIT="$DEFAULT_PBGUI_COMMIT"
SEL_PB7_COMMIT="$DEFAULT_PB7_COMMIT"
SEL_PB8_COMMIT="$DEFAULT_PB8_COMMIT"

echo ""
mini_divider
echo ""
echo -e "  ${BOLD}Component Version Selection${RESET}"
echo -e "  ${DIM}Downloads are strictly restricted to official GitHub repositories.${RESET}"
echo ""

if ! $NON_INTERACTIVE; then
    echo -e "  Choose component release versions to install:"
    echo ""
    echo -e "    ${DIM}1)${RESET}  Latest online releases        ${DIM}(PBGui: main · PB7: master · PB8: master)${RESET}"
    echo -e "    ${DIM}2)${RESET}  Verified tested versions      ${DIM}(PBGui: ${DEFAULT_PBGUI_COMMIT} · PB7: ${DEFAULT_PB7_COMMIT:0:8} · PB8: ${DEFAULT_PB8_COMMIT})${RESET} ${CYAN}[recommended]${RESET}"
    echo -e "    ${DIM}3)${RESET}  Custom commits or branches"
    echo ""
    echo -en "  ${CYAN}?${RESET} Your choice ${DIM}[2]${RESET}: "
    read -r _vchoice
    _vchoice="${_vchoice:-2}"

    case "$_vchoice" in
        1)
            SEL_PBGUI_COMMIT="main"
            SEL_PB7_COMMIT="master"
            SEL_PB8_COMMIT="master"
            info "Selected latest online releases."
            ;;
        2)
            SEL_PBGUI_COMMIT="$DEFAULT_PBGUI_COMMIT"
            SEL_PB7_COMMIT="$DEFAULT_PB7_COMMIT"
            SEL_PB8_COMMIT="$DEFAULT_PB8_COMMIT"
            info "Selected verified tested versions."
            ;;
        3)
            echo ""
            info "Specify valid git commit SHAs, tags, or branch names."
            prompt_input SEL_PBGUI_COMMIT "PBGui commit/branch" "$DEFAULT_PBGUI_COMMIT"
            prompt_input SEL_PB7_COMMIT   "Passivbot v7 commit/branch" "$DEFAULT_PB7_COMMIT"
            prompt_input SEL_PB8_COMMIT   "Passivbot v8 commit/branch" "$DEFAULT_PB8_COMMIT"

            for _ref in "$SEL_PBGUI_COMMIT" "$SEL_PB7_COMMIT" "$SEL_PB8_COMMIT"; do
                if [[ ! "$_ref" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
                    error "Invalid git reference name: '$_ref'. Only alphanumeric characters, '.', '_', '-' allowed."
                fi
            done
            ;;
        *)
            info "Defaulting to verified tested versions."
            ;;
    esac
fi

env_set PBGUI_COMMIT "$SEL_PBGUI_COMMIT"
env_set PB7_COMMIT "$SEL_PB7_COMMIT"
env_set PB8_COMMIT "$SEL_PB8_COMMIT"
success "Versions written to .env  ${DIM}(PBGui: ${SEL_PBGUI_COMMIT} · PB7: ${SEL_PB7_COMMIT:0:8} · PB8: ${SEL_PB8_COMMIT})${RESET}"

# ── pbgui.ini ─────────────────────────────────────────────────────────────────
# PBGui writes all UI-saved settings to pbgui.ini at runtime (CoinMarketCap
# API key, PBRemote bucket, PBData config, VPS Monitor settings, exchange
# configuration, …). The file is persisted inside the data/ volume
# (userdata/pbgui_data/pbgui.ini → /app/pbgui/data/pbgui.ini).

PBGUI_INI_FILE="${USERDATA_PATH}/pbgui_data/pbgui.ini"

echo ""
mini_divider
echo ""
echo -e "  ${BOLD}PBGui runtime configuration (pbgui.ini)${RESET}"
echo ""

if [ -f "$PBGUI_INI_FILE" ]; then
    warn "pbgui.ini already present — skipping  ${DIM}(customisations preserved)${RESET}"
else
    cat > "$PBGUI_INI_FILE" <<EOF
[main]
pb7dir = /app/pb7
pb7venv = /app/venv_pb7/bin/python
pb8dir = /app/pb8
pb8venv = /app/venv_pb8/bin/python
pbname = mypassivbot
role = master
[pbremote]
bucket = pbgui:
EOF
    chmod 600 "$PBGUI_INI_FILE"
    success "pbgui.ini created  ${DIM}(configured for dual engine PB7 + PB8)${RESET}"
fi

# ── Services ──────────────────────────────────────────────────────────────────
# Controls which background Python services are started at container boot.
# The selection is stored in userdata/pbgui_data/services.conf, which is
# already inside the mounted data/ volume — no image rebuild needed to change
# it later.  entrypoint.sh reads this file at startup.

SERVICES_CONF_FILE="${USERDATA_PATH}/pbgui_data/services.conf"

# Canonical list of optional background services.
# Format: "ScriptName.py|Short description|default(y/n)"
_SERVICES=(
    "PBRun.py|Bot runner — executes live trading instances (PB7 & PB8)|y"
    "PBData.py|Data manager — downloads and caches OHLCV data|y"
    "PBCoinData.py|CoinMarketCap data — market cap and coin info|y"
    "PBCluster.py|Cluster sync — node synchronization and credential manager|y"
    "monitor_agent.py|VPS Monitor agent — local system metrics and process monitor|y"
)

echo ""
mini_divider
echo ""
echo -e "  ${BOLD}Background Services${RESET}"
echo ""

if [ -f "$SERVICES_CONF_FILE" ]; then
    warn "services.conf already present — skipping  ${DIM}(edit manually to change)${RESET}"
else
    if ! $NON_INTERACTIVE; then
        echo -e "  ${DIM}Choose which services to start automatically when the container boots.${RESET}"
        echo -e "  ${DIM}All services are enabled by default; disable what you don't need to save resources.${RESET}"
        echo ""

        declare -A _svc_enabled
        for _entry in "${_SERVICES[@]}"; do
            IFS='|' read -r _script _desc _default <<< "$_entry"
            if mini_confirm "  Enable ${CYAN}${_script}${RESET}  ${DIM}(${_desc})${RESET}?" "$_default"; then
                _svc_enabled["$_script"]="true"
                success "${_script} enabled"
                echo ""
            else
                _svc_enabled["$_script"]="false"
                info "${_script} disabled"
                echo ""
            fi
        done
    else
        # Non-interactive: enable everything by default.
        declare -A _svc_enabled
        for _entry in "${_SERVICES[@]}"; do
            IFS='|' read -r _script _desc _default <<< "$_entry"
            _svc_enabled["$_script"]="true"
        done
        info "Non-interactive mode — all services enabled."
    fi

    # Write services.conf — one KEY=VALUE per line, parseable by bash and sh.
    {
        echo "# pbgui-docker — services.conf"
        echo "# Controls which background services start at container boot."
        echo "# Set to 'true' to enable, 'false' to disable."
        echo "# Changes take effect on the next 'docker compose restart'."
        echo ""
        for _entry in "${_SERVICES[@]}"; do
            IFS='|' read -r _script _desc _default <<< "$_entry"
            _key="ENABLE_$(echo "${_script%.py}" | tr '[:lower:]' '[:upper:]')"
            echo "# ${_desc}"
            echo "${_key}=${_svc_enabled[$_script]}"
        done
    } > "$SERVICES_CONF_FILE"

    chmod 644 "$SERVICES_CONF_FILE"
    success "services.conf created"
fi
unset _SERVICES _svc_enabled _entry _script _desc _default _key

# ── secrets.toml ──────────────────────────────────────────────────────────────
# Persisted inside userdata/pbgui_data/auth/secrets.toml -> /app/pbgui/data/auth/secrets.toml
# Secrets are loaded by FastAPI authentication endpoints at runtime.
# requires the parent directory to be a writable bind mount, not the file itself.

SECRETS_FILE="${USERDATA_PATH}/pbgui_data/auth/secrets.toml"
ENABLE_AUTH=false
AUTH_PASSWORD=""

echo ""
mini_divider
echo ""
echo -e "  ${BOLD}Authentication${RESET}"
echo ""

if [ -f "$SECRETS_FILE" ]; then
    warn "secrets.toml already present — skipping"
else
    if ! $NON_INTERACTIVE; then
        info "PBGui-Docker starts without a preset password."
        info "You can enable it now or later from the Web UI."
        echo ""
        if confirm "Enable password protection?" "y"; then
            ENABLE_AUTH=true
            while [ -z "$AUTH_PASSWORD" ]; do
                prompt_input AUTH_PASSWORD "Choose a password" "" secret
                [ -z "$AUTH_PASSWORD" ] && warn "Password cannot be empty — try again."
            done
        fi
    fi

    if $ENABLE_AUTH && [ -n "$AUTH_PASSWORD" ]; then
        AUTH_PASSWORD_SAFE="$(sanitize_string "$AUTH_PASSWORD")"
        mkdir -p "$(dirname "$SECRETS_FILE")"
        cat > "$SECRETS_FILE" <<EOF
# PBGui — FastAPI secrets
# Authentication: ENABLED

password = "${AUTH_PASSWORD_SAFE}"
EOF
        success "Password set successfully!"
    else
        mkdir -p "$(dirname "$SECRETS_FILE")"
        cat > "$SECRETS_FILE" <<'EOF'
# PBGui — FastAPI secrets
# Authentication: DISABLED (open access)
#
# To enable, add the line below and restart:
#   docker compose restart
#
# password = "your-strong-password"
EOF
        success "Authentication disabled!"
        warn "If you plan to make PBGui accessible over the internet, set a password through the UI as soon as possible."
    fi

    chmod 600 "$SECRETS_FILE"
fi

# ── rclone.conf ───────────────────────────────────────────────────────────────
# rclone reads its config from ~/.config/rclone/rclone.conf.  Inside the
# container the pbgui user's HOME is /app, so the effective path is
# /app/.config/rclone/rclone.conf — bind-mounted from userdata/rclone/.
# Mounted as a directory to allow atomic writes by rclone.

RCLONE_CONF_FILE="${USERDATA_PATH}/rclone/rclone.conf"

echo ""
mini_divider
echo ""
echo -e "  ${BOLD}rclone configuration (rclone.conf)${RESET}"
echo ""

if [ -f "$RCLONE_CONF_FILE" ]; then
    warn "rclone.conf already present — skipping  ${DIM}(credentials preserved)${RESET}"
else
    touch "$RCLONE_CONF_FILE"
    chmod 600 "$RCLONE_CONF_FILE"
    success "rclone.conf placeholder created  ${DIM}(configure PBRemote from the Web UI)${RESET}"
fi

# ── api-keys.json ─────────────────────────────────────────────────────────────

API_KEYS_FILE="${USERDATA_PATH}/api-keys.json"
EXCHANGE_NAME="binance"

echo ""
mini_divider
echo ""
echo -e "  ${BOLD}API keys${RESET}"
echo ""

if [ -f "$API_KEYS_FILE" ]; then
    warn "api-keys.json already present — skipping  ${DIM}(may contain live credentials)${RESET}"
else
    if ! $NON_INTERACTIVE; then
        info "A placeholder api-keys.json will be created."
        info "Add real credentials later from the Web UI."
        info "Supported exchanges: ${DIM}binance · bybit · bitget · gateio · hyperliquid · okx · kucoin · bingx${RESET}"
        echo ""
        prompt_input EXCHANGE_NAME "Default exchange" " [binance]"
    fi

    EXCHANGE_NAME_SAFE="$(sanitize_string "$EXCHANGE_NAME")"

    cat > "$API_KEYS_FILE" <<EOF
{
  "default_user": {
    "exchange": "${EXCHANGE_NAME_SAFE}",
    "key": "",
    "secret": ""
  }
}
EOF
    chmod 600 "$API_KEYS_FILE"
    success "api-keys.json created"
fi

# ── Ownership ─────────────────────────────────────────────────────────────────

# userdata: owned by the same UID/GID used to run the container process,
# so the application can read and write bind-mounted volumes without errors.
chown -R "${DOCKER_UID}:${DOCKER_GID}" "$USERDATA_PATH"
success "Ownership applied    ${DIM}${DOCKER_UID}:${DOCKER_GID} (container user)${RESET}"

# Repository top-level files: owned by the host Docker user so they can run
# docker compose commands without root after installation.
# userdata/ is excluded here — its ownership was set above.
if [ "$DOCKER_USER" != "root" ]; then
    find "$REPO_DIR" -maxdepth 1 ! -name "userdata" -exec chown "${DOCKER_USER}:${DOCKER_GID}" {} +
    success "Repository owned by  ${DIM}${DOCKER_USER}${RESET}"
fi

# ── Pre-launch summary ────────────────────────────────────────────────────────

HOST_IP=$(detect_host_ip)

echo ""
divider
echo ""
echo -e "  ${BOLD}Summary${RESET}"
echo ""
info "Environment      ${CYAN}${ENV_TYPE}${RESET}"
info "Install base     ${CYAN}${INSTALL_BASE}${RESET}"
info "Repository       ${CYAN}${REPO_DIR}${RESET}"
info "Userdata         ${CYAN}${USERDATA_PATH}${RESET}"
info "Docker user      ${CYAN}${DOCKER_USER}${RESET}  ${DIM}(uid=${DOCKER_UID}  gid=${DOCKER_GID})${RESET}"
$DATASET_CREATED && info "ZFS dataset      ${GREEN}created${RESET}  ${DIM}(${ZFS_DATASET})${RESET}"
if $ENABLE_AUTH; then
    info "Auth             ${GREEN}Enabled${RESET}"
else
    info "Auth             ${YELLOW}Disabled${RESET}"
fi
info "Web UI & API     ${CYAN}http://${HOST_IP}:${WEBUI_PORT}${RESET}"
echo ""
divider

if ! $NON_INTERACTIVE; then
    pause
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — Build & Launch
# ══════════════════════════════════════════════════════════════════════════════

nextstep "Build & Launch"

cd "$REPO_DIR"

USE_CACHE=true

if ! $NON_INTERACTIVE; then
    warn "Build note"
    echo ""
    info "The Docker image must compile a Rust extension (passivbot-rust)."
    info "This can take ${BOLD}5-10 minutes${RESET}, depending on your system."
    echo ""

    if confirm "Use Docker layer cache for the build?" "y"; then
        USE_CACHE=true
        info "Cache ${GREEN}enabled${RESET}  ${DIM}— unchanged layers will be reused (faster)${RESET}"
    else
        USE_CACHE=false
        info "Cache ${YELLOW}disabled${RESET}  ${DIM}— all layers will be rebuilt from scratch${RESET}"
    fi

    echo ""

    if ! confirm "Build and start the container now?" "y"; then
        success "Setup complete."
        echo ""
        info "When you're ready, run:"
        echo -e "    ${CYAN}cd ${REPO_DIR} && docker compose build --no-cache && docker compose up -d${RESET}"
        echo ""
        exit 0
    fi
fi

if $USE_CACHE; then
    docker compose build
else
    docker compose build --no-cache
fi

docker compose up -d

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9 — Wait for Healthy
# ══════════════════════════════════════════════════════════════════════════════

nextstep "Verifying Health"

TIMEOUT=180
INTERVAL=5
ELAPSED=0
CONTAINER_HEALTHY=false

echo -en "  ${DIM}Waiting for container to become healthy.${RESET}"

while [ $ELAPSED -lt $TIMEOUT ]; do
    STATUS=$(docker inspect \
        --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
        "$CONTAINER" 2>/dev/null || echo "not-found")

    case "$STATUS" in
        healthy)
            echo ""
            echo ""
            success "Container is healthy."
            CONTAINER_HEALTHY=true
            break
            ;;
        unhealthy)
            echo ""
            echo ""
            warn "Container reported unhealthy.  Check the logs:"
            echo ""
            echo -e "    ${CYAN}docker logs --tail 50 ${CONTAINER}${RESET}"
            break
            ;;
        no-healthcheck)
            echo ""
            echo ""
            warn "No healthcheck configured — assuming running."
            CONTAINER_HEALTHY=true
            break
            ;;
        not-found)
            echo ""
            echo ""
            error "Container '${CONTAINER}' not found after start.  Run 'docker compose ps' to investigate."
            ;;
        *)
            echo -en "${DIM}.${RESET}"
            ;;
    esac

    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ] && ! $CONTAINER_HEALTHY; then
    echo ""
    echo ""
    warn "Container did not report healthy within ${TIMEOUT}s — it may still be starting."
    info "Monitor with:  ${CYAN}docker logs -f ${CONTAINER}${RESET}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# DONE
# ══════════════════════════════════════════════════════════════════════════════

echo ""
divider
echo ""
echo -e "  ${GREEN}${BOLD}PBGui is up and running!${RESET}"
echo ""
info "Web UI & API  →  ${CYAN}http://${HOST_IP}:${WEBUI_PORT}${RESET}"
echo ""
divider
echo ""
echo -e "  ${BOLD}Useful commands${RESET}"
echo ""
if [ "$DOCKER_USER" != "root" ]; then
    echo -e "  ${DIM}Run the following as ${RESET}${CYAN}${DOCKER_USER}${RESET}${DIM} — switch with:${RESET}  ${CYAN}su - ${DOCKER_USER}${RESET}"
    echo ""
fi
echo -e "    ${DIM}View logs   ${RESET}${CYAN}docker logs -f ${CONTAINER}${RESET}"
echo -e "    ${DIM}Stop        ${RESET}${CYAN}docker compose down${RESET}"
echo -e "    ${DIM}Restart     ${RESET}${CYAN}docker compose restart${RESET}"
echo -e "    ${DIM}Rebuild     ${RESET}${CYAN}docker compose up -d --build --no-cache${RESET}"
echo -e "    ${DIM}Status      ${RESET}${CYAN}docker compose ps${RESET}"
echo ""
divider
echo ""
echo -e "  ${BOLD}${GREEN}Enjoyed using this installer?${RESET}"
echo -e "  Consider supporting the project with a small"
echo -e "  donation to help keep it alive and improving:"
echo -e "  ${BOLD}${CYAN}https://buymeacoffee.com/dreamelite96${RESET}"
echo ""
echo -e "  ${BOLD}${GREEN}Thanks for your support!${RESET}"
echo ""
