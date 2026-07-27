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

# entrypoint.sh — Sync pbgui.ini between the persistent data/ volume and the
# PBGui working directory, ensure FastAPI auth structure, and start PBApiServer.

set -euo pipefail

PERSISTENT_INI="/app/pbgui/data/pbgui.ini"
WORKING_INI="/app/pbgui/pbgui.ini"
DEFAULT_INI="/app/pbgui/pbgui.ini.default"

# ── Startup: seed persistent config if empty, then restore to working path ───
if [ ! -f "$PERSISTENT_INI" ] && [ -f "$DEFAULT_INI" ]; then
    echo "Seeding default pbgui.ini to persistent storage..."
    mkdir -p "$(dirname "$PERSISTENT_INI")"
    cp "$DEFAULT_INI" "$PERSISTENT_INI"
fi

if [ -f "$PERSISTENT_INI" ]; then
    cp "$PERSISTENT_INI" "$WORKING_INI"
fi

# ── Startup: Ensure auth directory and api-keys.json exist ────────────────────
mkdir -p /app/pbgui/data/auth
chmod 700 /app/pbgui/data/auth 2>/dev/null || true

# Ensure api-keys.json is initialized if missing to prevent directory auto-creation
if [ ! -f /app/pb7/api-keys.json ]; then
    mkdir -p /app/pb7
    echo '{"default_user":{"exchange":"binance","key":"","secret":""}}' > /app/pb7/api-keys.json
fi

# ── Startup: Ensure dual-engine PB7 and PB8 entries exist in pbgui.ini ──────
if [ -f "$WORKING_INI" ]; then
    /app/venv_pbgui/bin/python -c "
import sys
path = '$WORKING_INI'
try:
    with open(path, 'r') as f:
        content = f.read()
    if '[main]' in content and 'pb8dir' not in content:
        print('Updating pbgui.ini with Passivbot v8 engine configuration...')
        content = content.replace('[main]', '[main]\npb8venv = /app/venv_pb8/bin/python\npb8dir = /app/pb8')
        with open(path, 'w') as f:
            f.write(content)
except Exception as e:
    print(f'Warning: Failed to update pbgui.ini: {e}')
"
    cp "$WORKING_INI" "$PERSISTENT_INI" 2>/dev/null || true
fi

# ── Startup: clear stale PID files from previous container runs ──────────────
echo "Clearing stale PID files..."
rm -f /app/pbgui/data/pid/*.pid 2>/dev/null || true

# ── Background watcher: sync pbgui.ini → data/ whenever it changes ───────────
_watch_ini() {
    local last_mtime cur_mtime
    last_mtime=$(stat -c '%Y' "$WORKING_INI" 2>/dev/null || echo 0)
    while true; do
        sleep 5
        if [ -f "$WORKING_INI" ]; then
            cur_mtime=$(stat -c '%Y' "$WORKING_INI" 2>/dev/null || echo 0)
            if [ "$cur_mtime" != "$last_mtime" ]; then
                cp "$WORKING_INI" "$PERSISTENT_INI"
                last_mtime="$cur_mtime"
            fi
        fi
    done
}
_watch_ini &
WATCHER_PID=$!

# ── Shutdown trap: final sync + kill watcher ─────────────────────────────────
_cleanup() {
    if [ -f "$WORKING_INI" ]; then
        cp "$WORKING_INI" "$PERSISTENT_INI"
    fi
    kill "$WATCHER_PID" 2>/dev/null || true
}
trap _cleanup EXIT

# ── Start PBGui & Services ───────────────────────────────────────────────────
cd /app/pbgui

SERVICES_CONF="/app/pbgui/data/services.conf"

# Helper: read a KEY=VALUE from services.conf; returns "true" if absent
_svc_enabled() {
    local key="$1"
    if [ ! -f "$SERVICES_CONF" ]; then
        echo "true"
        return
    fi

    local val
    val=$(grep -E "^${key}=" "$SERVICES_CONF" 2>/dev/null \
          | tail -1 \
          | sed 's/^[^=]*=//' \
          | tr -d '[:space:]' \
          | tr -d '#')

    if [ "$val" = "false" ]; then
        echo "false"
    else
        echo "true"
    fi
}

[ "$(_svc_enabled ENABLE_PBRUN)"          = "true" ] && /app/venv_pbgui/bin/python PBRun.py &
[ "$(_svc_enabled ENABLE_PBDATA)"         = "true" ] && /app/venv_pbgui/bin/python PBData.py &
[ "$(_svc_enabled ENABLE_PBCOINDATA)"     = "true" ] && /app/venv_pbgui/bin/python PBCoinData.py &
[ "$(_svc_enabled ENABLE_PBCLUSTER)"      = "true" ] && /app/venv_pbgui/bin/python PBCluster.py &
[ "$(_svc_enabled ENABLE_MONITOR_AGENT)"  = "true" ] && /app/venv_pbgui/bin/python monitor_agent.py &

# Start the FastAPI-based API/Web UI server as the foreground process
exec /app/venv_pbgui/bin/python PBApiServer.py
