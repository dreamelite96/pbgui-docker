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
#   • /app/venv_pb8              (Passivbot v8 dependencies + rust extension)
#   • /app/venv_pbgui            (FastAPI PBGui dependencies)
#   • /app/pbgui /app/pb7 /app/pb8 (source clones)
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
ARG PBGUI_COMMIT=37942d20e4670e2c97c5477ec0af413a6e94a294
ARG PB7_COMMIT=fc6b9e016e04a3723bb5fe8847f1500049fa982c
ARG PB8_COMMIT=a0897f83932db5e6888c1c96f8f1c668d452013f

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
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Rust toolchain ────────────────────────────────────────────────────────────
# Passivbot v7 and v8 ship performance-critical extensions written in Rust
# (passivbot-rust) that must be compiled with maturin/pip at build time.
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
# (e.g. python3.12-venv) during update flows.
# Only the two specific commands actually needed are whitelisted.
RUN echo "pbgui ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt" \
    >> /etc/sudoers.d/pbgui \
    && chmod 440 /etc/sudoers.d/pbgui

# ── Clone source repositories (Strictly official GitHub remotes) ──────────────
# - pbgui : FastAPI-based web UI for managing Passivbot instances.
# - pb7   : Passivbot v7 trading bot engine.
# - pb8   : Passivbot v8 trading bot engine.
RUN git clone https://github.com/msei99/pbgui.git /app/pbgui \
    && git -C /app/pbgui checkout "${PBGUI_COMMIT}" \
    && git clone https://github.com/enarjord/passivbot.git /app/pb7 \
    && git -C /app/pb7 checkout "${PB7_COMMIT}" \
    && git clone https://github.com/enarjord/passivbot.git /app/pb8 \
    && git -C /app/pb8 checkout "${PB8_COMMIT}" \
    && chown -R pbgui:pbgui /app

USER pbgui

# ── Global PBGui dependencies (for Ansible subprocesses) ─────────────────────
# Installed in user site-packages (/app/.local) so Ansible-launched
# subprocesses can import PBGui modules without requiring manual venv activation.
RUN python3.12 -m pip install \
    --user \
    --no-cache-dir \
    --break-system-packages \
    --no-warn-script-location \
    -r /app/pbgui/requirements.txt

# ── Virtual environments ──────────────────────────────────────────────────────
# Each component gets its own venv to keep dependency trees fully independent:
# - venv_pb7   : Python 3.12 environment for Passivbot v7.
# - venv_pb8   : Python 3.12 environment for Passivbot v8.
# - venv_pbgui : Python 3.12 environment for the PBGui web application.
RUN python3.12 -m venv venv_pb7 \
    && python3.12 -m venv venv_pb8 \
    && python3.12 -m venv venv_pbgui

# ── Passivbot v7: pip deps + compile Rust extension ──────────────────────────
RUN --mount=type=cache,target=/opt/cargo/registry,mode=0777 \
    --mount=type=cache,target=/app/pb7/passivbot-rust/target,mode=0777 \
    . venv_pb7/bin/activate \
    && cd pb7 \
    && pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt \
    && cd passivbot-rust \
    && maturin develop --release \
    && ln -s /app/venv_pb7 /app/pb7/.venv

# ── Passivbot v8: pip deps + compile Rust extension ──────────────────────────
RUN --mount=type=cache,target=/opt/cargo/registry,mode=0777 \
    --mount=type=cache,target=/app/pb8/passivbot-rust/target,mode=0777 \
    . venv_pb8/bin/activate \
    && cd pb8 \
    && pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -e .[full] \
    && ln -s /app/venv_pb8 /app/pb8/.venv

# ── PBGui: pip deps ───────────────────────────────────────────────────────────
# Installs the web application's dependencies inside its dedicated venv.
RUN . venv_pbgui/bin/activate \
    && cd pbgui \
    && pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

# ── PBGui configuration file (pbgui.ini) ─────────────────────────────────────
# pbgui.ini is persisted via userdata/pbgui_data/ → /app/pbgui/data/ (already
# a directory mount). The entrypoint copies pbgui.ini from data/ into the
# working directory at every startup, and writes it back on clean exit.
# A default copy is placed in the working directory as pbgui.ini.default here so the
# first boot can seed the persistent volume with dual-engine paths (pb7 + pb8).
RUN printf '[main]\npb7dir = /app/pb7\npb7venv = /app/venv_pb7/bin/python\npb8dir = /app/pb8\npb8venv = /app/venv_pb8/bin/python\npbname = mypassivbot\nrole = master\n[pbremote]\nbucket = pbgui:\n' \
       > /app/pbgui/pbgui.ini.default


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
    PATH="/app/.local/bin:/opt/cargo/bin:${PATH}" \
    PYTHONPATH="/app/pb7:/app/pb8"

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
# • libgomp1          : OpenMP runtime required by numba.
# • python-is-python3 : makes bare `python` resolve to python3.
# • gcc + libc6-dev   : linker and development headers needed at runtime
#                       by maturin/cargo to compile Rust extensions.
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
    gcc \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/*

# Allow global pip installs on Python 3.12 (PEP 668 bypass for Ansible subprocs)
RUN rm -f /usr/lib/python3.12/EXTERNALLY-MANAGED

# ── Copy Rust toolchain from builder ─────────────────────────────────────────
COPY --from=builder --chown=pbgui:pbgui /opt/rustup /opt/rustup
COPY --from=builder --chown=pbgui:pbgui /opt/cargo  /opt/cargo

# ── Recreate runtime user with the same UID/GID ──────────────────────────────
RUN groupadd -r -g "${PBGUI_GID}" pbgui \
    && useradd -r -u "${PBGUI_UID}" -g pbgui -d /app -s /bin/bash pbgui \
    && chown pbgui:pbgui /app \
    && echo "pbgui ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt" \
       >> /etc/sudoers.d/pbgui \
    && chmod 440 /etc/sudoers.d/pbgui

# ── Copy application artifacts from builder ───────────────────────────────────
COPY --from=builder --chown=pbgui:pbgui /app/pbgui      /app/pbgui
COPY --from=builder --chown=pbgui:pbgui /app/pb7        /app/pb7
COPY --from=builder --chown=pbgui:pbgui /app/pb8        /app/pb8
COPY --from=builder --chown=pbgui:pbgui /app/venv_pb7   /app/venv_pb7
COPY --from=builder --chown=pbgui:pbgui /app/venv_pb8   /app/venv_pb8
COPY --from=builder --chown=pbgui:pbgui /app/venv_pbgui /app/venv_pbgui
COPY --from=builder --chown=pbgui:pbgui /app/.local      /app/.local

USER pbgui

# ── Exposed ports ─────────────────────────────────────────────────────────────
# 8000 : FastAPI REST interface & Web UI
EXPOSE 8000

# ── Container entrypoint ──────────────────────────────────────────────────────
COPY --chown=pbgui:pbgui entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

CMD ["/app/entrypoint.sh"]
