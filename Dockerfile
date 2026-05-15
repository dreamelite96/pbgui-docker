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

# ══════════════════════════════════════════════════════════════════════════════
# STAGE 1 — builder
# Installs all build-time dependencies (Rust toolchain, build-essential,
# deadsnakes PPA, Python 3.12) and produces:
#   • /opt/rustup + /opt/cargo   (Rust toolchain — copied to runtime because
#                                  PBGui's Ansible update flow calls rustup +
#                                  maturin develop --release at runtime)
#   • /app/venv_pb7              (compiled passivbot-rust wheel installed)
#   • /app/venv_pbgui
#   • /app/pbgui  /app/pb7       (source clones)
# Nothing from this stage's apt cache or build-essential layers
# leaks into the final image.
# ══════════════════════════════════════════════════════════════════════════════
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DEFAULT_TIMEOUT=120 \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PATH="/opt/cargo/bin:${PATH}"

ARG PBGUI_UID=1000
ARG PBGUI_GID=1000

WORKDIR /app

# ── System dependencies (build-time only) ────────────────────────────────────
# software-properties-common + deadsnakes: needed only to get Python 3.12.
# build-essential + curl: needed by pip packages with C extensions and by
# the rustup installer.
# All lists are purged in the same RUN layer to keep this stage lean.
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common \
    git \
    curl \
    build-essential \
    ansible \
    sudo \
    python-is-python3 \
    python3-pip \
    rclone \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update && apt-get install -y --no-install-recommends \
    python3.12 python3.12-venv python3.12-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Rust toolchain ────────────────────────────────────────────────────────────
# Passivbot v7 ships a performance-critical extension written in Rust
# (passivbot-rust) that must be compiled with maturin at build time.
# RUSTUP_HOME and CARGO_HOME are set to /opt paths (not /root) so the
# runtime non-root user (pbgui) can execute rustup, cargo, and rustc.
# chmod -R a+rwx ensures the toolchain remains accessible after USER switch.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path \
    && chmod -R a+rwx /opt/rustup /opt/cargo

# ── Runtime user (created in builder so owned files transfer correctly) ───────
# Creating the user here — before switching context — ensures that all files
# produced by subsequent build steps are owned by pbgui:pbgui from the start,
# so no recursive chown pass is needed when copying artifacts to the runtime
# stage with COPY --chown.
RUN groupadd -r -g "${PBGUI_GID}" pbgui \
    && useradd -r -u "${PBGUI_UID}" -g pbgui -d /app -s /bin/bash pbgui \
    && chown pbgui:pbgui /app

# ── Allow pbgui to install apt packages without a password ───────────────────
# PBGui's Ansible playbooks use `become: yes` to install system packages
# (e.g. python3.12-venv) during the PB7 update flow.
# Only the two specific commands actually needed are whitelisted.
RUN echo "pbgui ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt" \
    >> /etc/sudoers.d/pbgui \
    && chmod 440 /etc/sudoers.d/pbgui

USER pbgui

# ── Clone source repositories ─────────────────────────────────────────────────
# - pbgui : Streamlit-based web UI for managing Passivbot instances.
# - pb7   : Passivbot v7 trading bot engine (Rust-accelerated).
# --depth 1 keeps the clone shallow, reducing build time and image transfer size.
RUN git clone --depth 1 https://github.com/msei99/pbgui.git \
    && git clone --depth 1 https://github.com/enarjord/passivbot.git pb7

# ── Global PBGui dependencies (for Ansible subprocesses) ─────────────────────
# Installed system-wide (outside any venv) so that Ansible-launched subprocesses
# can import PBGui modules without requiring manual venv activation.
# --ignore-installed avoids version conflicts with Ansible's own packages.
# --break-system-packages is required on Ubuntu 23.04+ (PEP 668) when
# installing into the system Python as a non-root user.
RUN python3.12 -m pip install \
    --ignore-installed \
    --no-cache-dir \
    --break-system-packages \
    --no-warn-script-location \
    -r /app/pbgui/requirements.txt

# ── Virtual environments ──────────────────────────────────────────────────────
# Each component gets its own venv to keep dependency trees fully independent:
# - venv_pb7   : Python 3.12 environment for Passivbot v7.
# - venv_pbgui : Python 3.12 environment for the PBGui web application.
RUN python3.12 -m venv venv_pb7 \
    && python3.12 -m venv venv_pbgui

# ── Passivbot v7: pip deps + compile Rust extension ──────────────────────────
# Steps:
#  1. Install all Python dependencies declared in pb7/requirements.txt.
#  2. Compile the Rust extension (passivbot-rust) in release mode via maturin
#     for maximum runtime performance.
#  3. Symlink venv_pb7 to pb7/.venv so that maturin and other tooling can
#     auto-discover the virtual environment without explicit activation.
RUN . venv_pb7/bin/activate \
    && cd pb7 \
    && pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt \
    && cd passivbot-rust \
    && maturin develop --release \
    && ln -s /app/venv_pb7 /app/pb7/.venv

# ── PBGui: pip deps ───────────────────────────────────────────────────────────
# Installs the web application's dependencies inside its dedicated venv.
RUN . venv_pbgui/bin/activate \
    && cd pbgui \
    && pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# ── PBGui configuration file (pbgui.ini) ─────────────────────────────────────
# pbgui.ini is persisted via userdata/pbgui_data/ → /app/pbgui/data/ (already
# a directory mount).  The entrypoint copies pbgui.ini from data/ into the
# working directory at every startup, and writes it back on clean exit.
# A default copy is placed in data/ here so the first boot has a valid file.
# The actual working copy at /app/pbgui/pbgui.ini is written by the entrypoint
# and is never mounted directly, so configparser's atomic rename always works.
RUN mkdir -p /app/pbgui/data \
    && printf '[main]\npb7dir = /app/pb7\npb7venv = /app/venv_pb7/bin/python\npbname = mypassivbot\n[pbremote]\nbucket = pbgui:\n' \
       > /app/pbgui/data/pbgui.ini


# ══════════════════════════════════════════════════════════════════════════════
# STAGE 2 — runtime
# Lean Ubuntu 24.04 image that contains only what is needed to run PBGui and
# support the Ansible-based in-app update flow (git, rustup/cargo, maturin).
# build-essential and the deadsnakes PPA are NOT present here; Python 3.12
# is installed from the standard Ubuntu 24.04 Noble repos (it ships 3.12
# natively), so no PPA is required.
# ══════════════════════════════════════════════════════════════════════════════
FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DEFAULT_TIMEOUT=120 \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PATH="/opt/cargo/bin:${PATH}" \
    PYTHONPATH="/app/pb7"

ARG PBGUI_UID=1000
ARG PBGUI_GID=1000

WORKDIR /app

# ── Runtime system packages ───────────────────────────────────────────────────
# • python3.12 + venv : Ubuntu 24.04 Noble ships Python 3.12 natively —
#                       no PPA needed.
# • git               : required by Ansible update playbooks (git pull).
# • ansible           : PBGui's update mechanism.
# • sudo              : Ansible become for apt-get inside the container.
# • rclone            : pbremote sync feature.
# • curl              : healthcheck + rustup self-update path.
# • libgomp1          : OpenMP runtime required by numba (pb7 dep).
# • python-is-python3 : makes bare `python` resolve to python3.
# build-essential and software-properties-common are intentionally absent.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ansible \
    sudo \
    rclone \
    python-is-python3 \
    python3-pip \
    python3.12 \
    python3.12-venv \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# ──────────────────────────────────────────────────────────────────────────────
# Allow global pip installs on Python 3.12
# Ubuntu 23.04+ marks system Python as "externally managed" (PEP 668), which
# prevents direct pip usage outside a virtual environment. Removing this marker
# lets PBGui's dependencies be installed globally so that Ansible subprocesses
# spawned by PBGui can import them without activating any venv.
# ──────────────────────────────────────────────────────────────────────────────
RUN rm -f /usr/lib/python3.12/EXTERNALLY-MANAGED

# ── Copy Rust toolchain from builder ─────────────────────────────────────────
# Needed at runtime because the Ansible update playbook runs:
#   rustup toolchain install/update  →  maturin develop --release
# Copying the pre-built toolchain avoids re-downloading it on every update.
COPY --from=builder /opt/rustup /opt/rustup
COPY --from=builder /opt/cargo  /opt/cargo

# ── Recreate runtime user with the same UID/GID ──────────────────────────────
# The user must be recreated in the runtime stage because /etc/passwd and
# /etc/group are not shared between stages. Using the same UID/GID values
# guarantees that file ownership is preserved for all artifacts copied from
# the builder stage, and that bind-mounted volumes on the host are accessible
# without permission errors.
RUN groupadd -r -g "${PBGUI_GID}" pbgui \
    && useradd -r -u "${PBGUI_UID}" -g pbgui -d /app -s /bin/bash pbgui \
    && chown pbgui:pbgui /app \
    && echo "pbgui ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt" \
       >> /etc/sudoers.d/pbgui \
    && chmod 440 /etc/sudoers.d/pbgui

# ── Copy application artifacts from builder ───────────────────────────────────
# Only the files strictly needed at runtime are transferred; build-time
# tooling (build-essential, deadsnakes PPA, apt lists) stays in the builder
# stage and never inflates the final image size.
# --chown ensures ownership is set atomically during the copy, with no need
# for a subsequent RUN chown pass.
COPY --from=builder --chown=pbgui:pbgui /app/pbgui      /app/pbgui
COPY --from=builder --chown=pbgui:pbgui /app/pb7        /app/pb7
COPY --from=builder --chown=pbgui:pbgui /app/venv_pb7   /app/venv_pb7
COPY --from=builder --chown=pbgui:pbgui /app/venv_pbgui /app/venv_pbgui

# ── Copy global pip packages installed system-wide for Ansible subprocesses ──
# These live under the pbgui home (.local) because pip used --break-system-packages
# with a non-root user; the entire .local tree is transferred.
COPY --from=builder --chown=pbgui:pbgui /app/.local /app/.local

USER pbgui

# ── Exposed ports ─────────────────────────────────────────────────────────────
# 8501 : Streamlit web interface (PBGui)
# 8000 : FastAPI REST interface   (PBGui optional API)
EXPOSE 8501
EXPOSE 8000

# ── Container entrypoint ──────────────────────────────────────────────────────
# entrypoint.sh syncs pbgui.ini between the persistent data/ volume and the
# working directory before starting Streamlit, so configparser's atomic rename
# (write .tmp → rename to final) always operates on a regular file rather than
# a mount point — avoiding [Errno 16] Device or resource busy on every save.
COPY --chown=pbgui:pbgui entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

CMD ["/app/entrypoint.sh"]
