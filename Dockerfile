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

# ──────────────────────────────────────────────────────────────────────────────
# Base image: Ubuntu 24.04 LTS (Noble Numbat)
# Provides a modern, well-supported foundation for all runtime components.
# ──────────────────────────────────────────────────────────────────────────────
FROM ubuntu:24.04

# Suppress interactive prompts during apt installations
# (e.g. timezone selection, keyboard layout dialogs).
ENV DEBIAN_FRONTEND=noninteractive

# All application components are installed under /app.
WORKDIR /app

# ──────────────────────────────────────────────────────────────────────────────
# System dependencies
# ──────────────────────────────────────────────────────────────────────────────
# - software-properties-common : register the deadsnakes PPA for newer Python builds
# - git                        : clone source repositories at image build time
# - curl                       : download the Rust toolchain installer
# - build-essential            : C/C++ toolchain required by several Python packages
# - ansible                    : used by PBGui to run remote bot-management tasks
# - python-is-python3          : makes the bare `python` command resolve to python3
# - python3-pip                : system pip, used to bootstrap virtual environments
# - python3.12 + venv + dev    : Python runtime for both PBGui and Passivbot v7
# ──────────────────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    software-properties-common \
    git \
    curl \
    build-essential \
    ansible \
    python-is-python3 \
    python3-pip \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update && apt-get install -y \
    python3.12 python3.12-venv python3.12-dev \
    && rm -rf /var/lib/apt/lists/*

# ──────────────────────────────────────────────────────────────────────────────
# Rust toolchain
# Passivbot v7 ships a performance-critical extension written in Rust
# (passivbot-rust) that must be compiled with maturin at image build time.
# ──────────────────────────────────────────────────────────────────────────────
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# ──────────────────────────────────────────────────────────────────────────────
# Allow global pip installs on Python 3.12
# Ubuntu 23.04+ marks system Python as "externally managed" (PEP 668), which
# prevents direct pip usage outside a virtual environment. Removing this marker
# lets PBGui's dependencies be installed globally so that Ansible subprocesses
# spawned by PBGui can import them without activating any venv.
# ──────────────────────────────────────────────────────────────────────────────
RUN rm -f /usr/lib/python3.12/EXTERNALLY-MANAGED

# ──────────────────────────────────────────────────────────────────────────────
# Clone source repositories
# - pbgui : Streamlit-based web UI for managing Passivbot instances
# - pb7   : Passivbot v7 trading bot engine (Rust-accelerated)
# ──────────────────────────────────────────────────────────────────────────────
RUN git clone https://github.com/msei99/pbgui.git \
    && git clone https://github.com/enarjord/passivbot.git pb7

# ──────────────────────────────────────────────────────────────────────────────
# Global PBGui dependencies
# Installed system-wide (outside any venv) so that Ansible-launched subprocesses
# can import PBGui modules without requiring manual venv activation.
# --ignore-installed avoids version conflicts with Ansible's own packages.
# ──────────────────────────────────────────────────────────────────────────────
RUN python3.12 -m pip install --ignore-installed -r /app/pbgui/requirements.txt

# ──────────────────────────────────────────────────────────────────────────────
# Isolated virtual environments
# Each component gets its own venv to keep dependency trees fully independent:
# - venv_pb7   : Python 3.12 environment for Passivbot v7
# - venv_pbgui : Python 3.12 environment for the PBGui web application
# ──────────────────────────────────────────────────────────────────────────────
RUN python3.12 -m venv venv_pb7 \
    && python3.12 -m venv venv_pbgui

# ──────────────────────────────────────────────────────────────────────────────
# Set up Passivbot v7 (PB7)
# Steps:
#  1. Install all Python dependencies declared in pb7/requirements.txt.
#  2. Compile the Rust extension (passivbot-rust) in release mode via maturin
#     for maximum runtime performance.
#  3. Symlink venv_pb7 to pb7/.venv so that maturin and other tooling can
#     auto-discover the virtual environment without explicit activation.
# ──────────────────────────────────────────────────────────────────────────────
RUN . venv_pb7/bin/activate \
    && cd pb7 \
    && pip install --upgrade pip \
    && pip install -r requirements.txt \
    && cd passivbot-rust \
    && maturin develop --release \
    && ln -s /app/venv_pb7 /app/pb7/.venv

# ──────────────────────────────────────────────────────────────────────────────
# Set up PBGui
# Installs the web application's dependencies inside its dedicated venv.
# ──────────────────────────────────────────────────────────────────────────────
RUN . venv_pbgui/bin/activate \
    && cd pbgui \
    && pip install --upgrade pip \
    && pip install -r requirements.txt

# ──────────────────────────────────────────────────────────────────────────────
# PBGui configuration file (pbgui.ini)
# Tells PBGui where Passivbot v7 is installed and which Python interpreter to
# use when launching it. The [pbremote] section configures the optional
# rclone-based remote-sync bucket (set to a local passthrough by default).
# ──────────────────────────────────────────────────────────────────────────────
RUN echo "[main]" > /app/pbgui/pbgui.ini && \
    echo "pb7dir = /app/pb7" >> /app/pbgui/pbgui.ini && \
    echo "pb7venv = /app/venv_pb7/bin/python" >> /app/pbgui/pbgui.ini && \
    echo "pbname = mypassivbot" >> /app/pbgui/pbgui.ini && \
    echo "[pbremote]" >> /app/pbgui/pbgui.ini && \
    echo "bucket = pbgui:" >> /app/pbgui/pbgui.ini

# ──────────────────────────────────────────────────────────────────────────────
# Python module path
# Adds pb7 to PYTHONPATH so its internal modules can be imported by PBGui and
# other components without needing to install pb7 as a formal package.
# ──────────────────────────────────────────────────────────────────────────────
ENV PYTHONPATH="/app/pb7"

# ──────────────────────────────────────────────────────────────────────────────
# Exposed ports
# 8501 : Streamlit web interface (PBGui)
# 8000 : FastAPI REST interface   (PBGui optional API)
# ──────────────────────────────────────────────────────────────────────────────
EXPOSE 8501
EXPOSE 8000

# ──────────────────────────────────────────────────────────────────────────────
# Container entrypoint
# Starts the PBGui Streamlit application, binding to all interfaces (0.0.0.0)
# so that the port published by Docker is reachable from the host machine.
# ──────────────────────────────────────────────────────────────────────────────
CMD ["/bin/bash", "-c", "cd /app/pbgui && /app/venv_pbgui/bin/streamlit run pbgui.py --server.address=0.0.0.0"]
