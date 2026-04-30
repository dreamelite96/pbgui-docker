#!/bin/bash

# ──────────────────────────────────────────────────────────────────────────────
# Copyright (C) 2026 @dreamelite96
# SPDX-License-Identifier: GPL-3.0-or-later
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
divider() { echo -e "${DIM}  ──────────────────────────────────────────────────────${RESET}"; }
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
TOTAL_STEPS=8
nextstep() {
    STEP=$((STEP + 1))
    echo ""
    echo ""
    echo -e "${BOLD}${BLUE}  [${STEP}/${TOTAL_STEPS}]  ${1}${RESET}"
    divider
}

# ─── Project constants ────────────────────────────────────────────────────────
REPO_URL="https://github.com/dreamelite96/pbgui-docker.git"
REPO_DIRNAME="pbgui-docker"
WEBUI_PORT="8501"
API_PORT="8000"

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

# ─── Input sanitisation helpers ──────────────────────────────────────────────

# Escapes backslashes and double-quotes so the value is safe inside a
# double-quoted JSON string literal produced via heredoc.
sanitize_json_string() {
    local val="$1"
    val="${val//\\/\\\\}"   # \ → \\
    val="${val//\"/\\\"}"   # " → \"
    echo "$val"
}

# Escapes backslashes and double-quotes so the value is safe inside a
# double-quoted TOML string literal produced via heredoc.
sanitize_toml_string() {
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
echo -e "  ${DIM}2.${RESET}  Detect environment     ${DIM}TrueNAS or Linux${RESET}"
echo -e "  ${DIM}3.${RESET}  Choose install path    ${DIM}base dir → ${REPO_DIRNAME}/ created inside${RESET}"
echo -e "  ${DIM}4.${RESET}  Provision storage      ${DIM}ZFS dataset on TrueNAS · plain dir on Linux${RESET}"
echo -e "  ${DIM}5.${RESET}  Clone repository       ${DIM}from GitHub${RESET}"
echo -e "  ${DIM}6.${RESET}  Write configuration    ${DIM}userdata dirs · api-keys.json · secrets.toml${RESET}"
echo -e "  ${DIM}7.${RESET}  Build & launch         ${DIM}docker compose up -d --build${RESET}"
echo -e "  ${DIM}8.${RESET}  Verify health          ${DIM}polls the built-in healthcheck${RESET}"
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

success "docker           $(docker --version  | grep -oP '\d+\.\d+\.\d+' | head -1)"
success "docker compose   $(docker compose version | grep -oP '\d+\.\d+\.\d+' | head -1)"
success "git              $(git --version | awk '{print $3}')"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — Environment Detection
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
# STEP 3 — Install Location
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
# STEP 4 — Storage Provisioning
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
                            # FIX #1: guard against zfs not being in PATH
                            command -v zfs &>/dev/null || error "'zfs' not found in PATH — cannot create dataset ${_current}."
                            zfs create -p "$_current"
                            success "Dataset created (zfs)      ${_current}"
                        fi
                    fi
                done
            else
                # FIX #1: guard against zfs not being in PATH
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
# STEP 5 — Repository
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

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — Files & Configuration
# ══════════════════════════════════════════════════════════════════════════════

nextstep "Files & Configuration"

# Subdirectory layout:
#   pbgui_data/                    — PBGui runtime state (bots, UI preferences)
#   historical_data/               — OHLCV market data, shared across tools
#   configs/                       — App-level config (secrets.toml, ...)
#   pb7/configs/                   — Passivbot v7 live trading configs
#   pb7/backtests/                 — Backtest result archives
#   pb7/optimize_results/          — Raw optimisation outputs
#   pb7/optimize_results_analysis/ — Post-processed optimisation reports
#   pb7/caches/                    — Cached market data for faster reruns

SUBDIRS=(
    pbgui_data
    historical_data
    configs
    pb7/configs
    pb7/backtests
    pb7/optimize_results
    pb7/optimize_results_analysis
    pb7/caches
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

chmod -R 755 "$USERDATA_PATH"
success "Permissions applied  ${DIM}755 (recursive)${RESET}"

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

    EXCHANGE_NAME_SAFE="$(sanitize_json_string "$EXCHANGE_NAME")"

    cat > "$API_KEYS_FILE" <<EOF
{
  "default_user": {
    "exchange": "${EXCHANGE_NAME_SAFE}",
    "key": "",
    "secret": ""
  }
}
EOF
    success "api-keys.json created"
fi

# ── secrets.toml ──────────────────────────────────────────────────────────────

SECRETS_FILE="${USERDATA_PATH}/configs/secrets.toml"
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
        AUTH_PASSWORD_SAFE="$(sanitize_toml_string "$AUTH_PASSWORD")"
        cat > "$SECRETS_FILE" <<EOF
# PBGui — Streamlit secrets
# Authentication: ENABLED

password = "${AUTH_PASSWORD_SAFE}"
EOF
        success "Password set successfully!"
    else
        cat > "$SECRETS_FILE" <<'EOF'
# PBGui — Streamlit secrets
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
$DATASET_CREATED && info "ZFS dataset      ${GREEN}created${RESET}  ${DIM}(${ZFS_DATASET})${RESET}"
if $ENABLE_AUTH; then
    info "Auth             ${GREEN}Enabled${RESET}"
else
    info "Auth             ${YELLOW}Disabled${RESET}"
fi
info "Web UI           ${CYAN}http://${HOST_IP}:${WEBUI_PORT}${RESET}"
info "FastAPI          ${CYAN}http://${HOST_IP}:${API_PORT}${RESET}"
echo ""
divider

if ! $NON_INTERACTIVE; then
    pause
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — Build & Launch
# ══════════════════════════════════════════════════════════════════════════════

nextstep "Build & Launch"

cd "$REPO_DIR"

if ! $NON_INTERACTIVE; then
    warn "First-time build note"
    echo ""
    info "The Docker image must compile a Rust extension (passivbot-rust)."
    info "This can take ${BOLD}5–10 minutes${RESET}, depending on your system."
    info "Subsequent builds are much faster thanks to Docker layer caching."
    echo ""
    if ! confirm "Build and start the container now?" "y"; then
        success "Setup complete."
        echo ""
        info "When you're ready, run:"
        echo -e "    ${CYAN}cd ${REPO_DIR} && sudo docker compose up -d --build${RESET}"
        echo ""
        exit 0
    fi
fi

docker compose up -d --build

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — Wait for Healthy
# ══════════════════════════════════════════════════════════════════════════════

nextstep "Verifying Health"

CONTAINER="pbgui"
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
info "Web UI (Streamlit)  →  ${CYAN}http://${HOST_IP}:${WEBUI_PORT}${RESET}"
info "Web UI (FastAPI)    →  ${CYAN}http://${HOST_IP}:${API_PORT}${RESET}"
echo ""
divider
echo ""
echo -e "  ${BOLD}Useful commands${RESET}"
echo ""
echo -e "    ${DIM}View logs   ${RESET}${CYAN}docker logs -f pbgui${RESET}"
echo -e "    ${DIM}Stop        ${RESET}${CYAN}docker compose down${RESET}"
echo -e "    ${DIM}Restart     ${RESET}${CYAN}docker compose restart${RESET}"
echo -e "    ${DIM}Rebuild     ${RESET}${CYAN}docker compose up -d --build --no-cache${RESET}"
echo -e "    ${DIM}Status      ${RESET}${CYAN}docker compose ps${RESET}"
echo ""
divider
echo ""
