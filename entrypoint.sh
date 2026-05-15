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
# PBGui working directory, then start Streamlit.
#
# Root cause: pbgui.ini is always read and written at its absolute path
# /app/pbgui/pbgui.ini (via PBGDIR from pbgui_purefunc.py).  When saving,
# PBGui (configparser) writes a .tmp file then renames it to pbgui.ini —
# an atomic operation that fails with [Errno 16] Device or resource busy
# if pbgui.ini itself is a Docker bind-mount (file-level mount = mount point
# the container cannot unlink or rename over).
#
# Solution: pbgui.ini is persisted inside the already-mounted data/ volume
# (userdata/pbgui_data/ → /app/pbgui/data/).  This script copies it to the
# working location at startup so PBGui always operates on a regular file,
# and writes it back on clean shutdown so the next container boot picks up
# any changes saved during the session.

set -euo pipefail

PERSISTENT_INI="/app/pbgui/data/pbgui.ini"
WORKING_INI="/app/pbgui/pbgui.ini"

# ── Startup: restore saved config into the working location ──────────────────
if [ -f "$PERSISTENT_INI" ]; then
    cp "$PERSISTENT_INI" "$WORKING_INI"
fi

# ── Background watcher: sync pbgui.ini → data/ whenever it changes ───────────
# docker stop sends SIGTERM directly to the PID 1 process (Streamlit after
# exec), bypassing any bash trap — so copy-on-shutdown is unreliable.
# Instead, a background loop polls the working file every 5 seconds and
# copies it to the persistent location as soon as its mtime changes.
# This guarantees the last saved state is persisted regardless of how the
# container stops (SIGTERM, SIGKILL, OOM, crash).
_watch_ini() {
    local last_mtime=0 cur_mtime
    while true; do
        if [ -f "$WORKING_INI" ]; then
            cur_mtime=$(stat -c '%Y' "$WORKING_INI" 2>/dev/null || echo 0)
            if [ "$cur_mtime" != "$last_mtime" ]; then
                cp "$WORKING_INI" "$PERSISTENT_INI"
                last_mtime="$cur_mtime"
            fi
        fi
        sleep 5
    done
}
_watch_ini &
WATCHER_PID=$!

# ── Shutdown trap: final sync + kill watcher ─────────────────────────────────
# This trap fires when the entrypoint shell exits (after Streamlit returns),
# not on SIGTERM to Streamlit itself — but it covers clean exit paths.
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
# (fail-open: missing file or missing key → service starts).
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

[ "$(_svc_enabled ENABLE_PBRUN)"      = "true" ] && /app/venv_pbgui/bin/python PBRun.py &
[ "$(_svc_enabled ENABLE_PBREMOTE)"   = "true" ] && /app/venv_pbgui/bin/python PBRemote.py &
[ "$(_svc_enabled ENABLE_PBMON)"      = "true" ] && /app/venv_pbgui/bin/python PBMon.py &
[ "$(_svc_enabled ENABLE_PBDATA)"     = "true" ] && /app/venv_pbgui/bin/python PBData.py &
[ "$(_svc_enabled ENABLE_PBCOINDATA)" = "true" ] && /app/venv_pbgui/bin/python PBCoinData.py &

/app/venv_pbgui/bin/streamlit run pbgui.py --server.address=0.0.0.0
