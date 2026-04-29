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

# setup.sh — Bootstrap the userdata directory structure for PBGui + Passivbot v7.
#
# Usage:
#   ./setup.sh                            → creates ./userdata  (default)
#   ./setup.sh /mnt/tank/pbgui/userdata   → custom path, e.g. a TrueNAS ZFS dataset
#
# The script is fully idempotent: re-running it on an existing installation is
# always safe. Pre-existing files (api-keys.json, secrets.toml) are never
# overwritten, preserving any credentials or settings already in place.

set -euo pipefail

# ─── ANSI colour helpers ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[ OK ]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERR ]${RESET} $*" >&2; exit 1; }

# ─── Target userdata path ─────────────────────────────────────────────────────
# Accepts an optional first argument so the same script works on plain Linux
# (path created automatically when absent) and on TrueNAS (where the ZFS
# dataset must already exist and be mounted before this script runs).
USERDATA_PATH="${1:-./userdata}"

# ─── Runtime environment detection ───────────────────────────────────────────
# Distinguishes between a standard Linux host and a TrueNAS Scale/Core system.
# On TrueNAS the script refuses to create the root directory itself because
# storage datasets must be provisioned through the TrueNAS UI or CLI.
detect_environment() {
    if [ -f /etc/truenas ] || grep -qi "truenas\|freenas" /etc/os-release 2>/dev/null; then
        echo "truenas"
    else
        echo "linux"
    fi
}   # <-- closing brace is mandatory: without it, the entire rest of this script
    #     would be parsed as the function body and never executed at the top level.

ENV_TYPE=$(detect_environment)

echo -e "\n${BOLD}PBGui Setup — Userdata Initialisation${RESET}"
echo -e "Detected environment: ${CYAN}${ENV_TYPE}${RESET}"
echo -e "Target path         : ${CYAN}${USERDATA_PATH}${RESET}\n"

# ─── Userdata root directory ──────────────────────────────────────────────────
# On TrueNAS the root must already exist as a pre-created ZFS dataset.
# On a standard Linux host it is created automatically when absent.
if [ -d "$USERDATA_PATH" ]; then
    if mountpoint -q "$USERDATA_PATH" 2>/dev/null; then
        warn "\"$USERDATA_PATH\" is an active mount point (ZFS dataset / Docker volume)."
        warn "It will be used as-is — the root directory itself will not be modified."
    else
        info "\"$USERDATA_PATH\" already exists. Skipping root creation."
    fi
else
    if [ "$ENV_TYPE" = "truenas" ]; then
        error "On TrueNAS, \"$USERDATA_PATH\" does not exist.\n" \
              "Please create the ZFS dataset and mount it at that path first, then re-run this script."
    fi
    info "Creating \"$USERDATA_PATH\"..."
    mkdir -p "$USERDATA_PATH"
    success "\"$USERDATA_PATH\" created."
fi

# ─── Required subdirectories ──────────────────────────────────────────────────
# Directory layout:
#   pbgui_data/                — PBGui runtime state (active bots, UI preferences)
#   historical_data/           — Downloaded OHLCV market data, shared across tools
#   configs/                   — Application-level config files (e.g. secrets.toml)
#   pb7/configs/               — Passivbot v7 live trading configuration files
#   pb7/backtests/             — Backtest result archives
#   pb7/optimize_results/      — Raw optimisation output files
#   pb7/optimize_results_analysis/ — Post-processed optimisation reports
#   pb7/caches/                — Cached market data used to speed up subsequent runs
info "Checking / creating required subdirectories..."

SUBDIRS=(
    pbgui_data
    historical_data
    configs
    pb7/configs
    pb7/backtests
    pb7/optimize_results
    pb7/optimize_results_analysis
    pb7/caches
)   # <-- closing parenthesis is mandatory: without it, the for loop below would
    #     be parsed as additional array elements and never execute.

for dir in "${SUBDIRS[@]}"; do
    target="${USERDATA_PATH}/${dir}"
    if [ -d "$target" ]; then
        warn "  Already exists: ${dir}"
    else
        mkdir -p "$target"
        success "  Created: ${dir}"
    fi
done

# ─── api-keys.json ────────────────────────────────────────────────────────────
# Stores exchange API credentials consumed by Passivbot v7.
# A minimal JSON template is created on first run; real credentials must be
# filled in manually before starting the bot. The file is never overwritten
# if it already exists, protecting any live credentials stored inside.
API_KEYS_FILE="${USERDATA_PATH}/api-keys.json"

if [ -f "$API_KEYS_FILE" ]; then
    warn "api-keys.json already present — skipping (may contain live credentials)."
else
    info "Creating api-keys.json template..."
    cat > "$API_KEYS_FILE" <<'EOF'
{
  "default_user": {
    "exchange": "binance",
    "key": "",
    "secret": ""
  }
}
EOF
    success "  api-keys.json created."
fi

# ─── secrets.toml ─────────────────────────────────────────────────────────────
# Streamlit reads this file at startup for application secrets and settings.
#
# Authentication policy (intentional — no login required by default):
# PBGui shows a login prompt only when a [passwords] section is present in this
# file. Omitting that section disables authentication entirely, which is the
# intended behaviour for a private, self-hosted deployment.
#
# To enable password protection, add the following lines to secrets.toml:
#
#   [passwords]
#   pbgui = "your-strong-password"
#
# The file is never overwritten if it already exists.
SECRETS_FILE="${USERDATA_PATH}/configs/secrets.toml"

if [ -f "$SECRETS_FILE" ]; then
    warn "secrets.toml already present — skipping."
else
    info "Creating secrets.toml (no password — open access)..."
    cat > "$SECRETS_FILE" <<'EOF'
# PBGui — Streamlit secrets
#
# Authentication is DISABLED by default (no [passwords] section).
# PBGui will start without asking for a login.
#
# To enable password protection, uncomment and fill in the lines below:
#
# [passwords]
# pbgui = "your-strong-password"
EOF
    success "  secrets.toml created (authentication disabled — no password required)."
fi

echo -e "\n${GREEN}${BOLD}Setup complete.${RESET}"
echo -e "Next steps:"
echo -e "  1. Edit ${CYAN}${API_KEYS_FILE}${RESET} and add your exchange API credentials."
echo -e "  2. To enable login protection, edit ${CYAN}${SECRETS_FILE}${RESET}"
echo -e "     and uncomment the [passwords] section."
echo -e "  3. Run ${CYAN}docker compose up -d${RESET} to start the stack.\n"
