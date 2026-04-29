# PBGui-Docker

[![Docker](https://img.shields.io/badge/Docker-container-2496ED?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Python](https://img.shields.io/badge/Python-3.12-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://www.python.org/)

## Overview

**PBGui-Docker** provides a ready-to-use Docker setup to deploy [PBGui](https://github.com/msei99/pbgui) by msei99 — a Streamlit-based web GUI for managing [Passivbot v7](https://github.com/enarjord/passivbot) trading bot instances — inside an isolated Docker container.

The image is built on **Ubuntu 24.04 LTS** and bundles the full dependency stack at build time:

- **Python 3.12** (via the deadsnakes PPA)
- **Rust toolchain** (required to compile `passivbot-rust`, the performance-critical Rust extension of Passivbot v7)
- **Ansible** (used internally by PBGui for remote bot management)
- Two isolated Python virtual environments: one for PBGui (`venv_pbgui`) and one for Passivbot v7 (`venv_pb7`)

> **Note:** This is an independent, community-made project. It is not affiliated with or endorsed by the original PBGui author.


## Features

- 🐳 **Cross-platform** — works on Linux, macOS, and Windows via Docker
- ⚡ **One-command setup** — no manual Python, Rust, or Ansible installation required
- 🔒 **Security-hardened** — runs with dropped Linux capabilities and `no-new-privileges`
- 🔄 **Idempotent setup script** — safely re-runnable; never overwrites existing credentials
- 💾 **Persistent volumes** — all data, configs, backtests, and API keys survive container restarts
- 🩺 **Healthcheck built-in** — Docker automatically monitors the Streamlit interface
- 🖥️ **TrueNAS Scale compatible** — `setup.sh` detects TrueNAS environments and adapts accordingly


## Requirements

- [Docker](https://docs.docker.com/get-docker/) v20.10+
- [Docker Compose](https://docs.docker.com/compose/install/) v2.0+
- A valid exchange API key (Bybit, Bitget, OKX, Binance and many others) for Passivbot v7


## Project Structure

```
pbgui-docker/
├── Dockerfile              # Container image definition (Ubuntu 24.04 LTS + Python 3.12 + Rust)
├── docker-compose.yml      # Service orchestration with volumes, ports, and security config
├── setup.sh                # Userdata directory bootstrap script
└── README.md               # This file
```

***

## Installation

### 1. Clone this repository

```bash
git clone https://github.com/dreamelite96/pbgui-docker.git
cd pbgui-docker
```

### 2. Run the setup script

The script creates the `userdata/` directory structure and generates template config files.

```bash
chmod +x setup.sh
./setup.sh
```

On **TrueNAS Scale**, pass your pre-created ZFS dataset path as an argument:

```bash
./setup.sh /mnt/tank/pbgui/userdata
```

> The script is fully idempotent — re-running it on an existing installation is always safe and will never overwrite existing credentials.

### 3. Build and start the container

```bash
docker compose up -d --build
```

> ⚠️ Once started, remember to **set the password** directly from the Web UI or by modifying the `userdata/configs/secrets.toml` file.

***

## Configuration

### Configure your API keys

API keys can be configured directly from the **PBGui web interface** at `http://localhost:8501` — no manual file editing required.

Alternatively, you can edit `userdata/api-keys.json` directly:

```json
{
  "default_user": {
    "exchange": "YOUR_EXCHANGE",
    "key": "YOUR_API_KEY",
    "secret": "YOUR_API_SECRET"
  }
}
```

### Enable password protection

By default, PBGui starts without authentication — suitable for private, self-hosted deployments. The login password can be set directly from the **PBGui web interface** at `http://localhost:8501`.

Alternatively, you can enable it manually by editing `userdata/configs/secrets.toml` and uncommenting:

```toml
[passwords]
pbgui = "your-strong-password"
```

***

## Accessing the Interface

| Interface | URL |
|---|---|
| WebUI (Streamlit) | http://localhost:8501 |
| New WebUI (FastAPI) | http://localhost:8000 |

***

## Volumes & Persistent Data

All persistent data is stored under `./userdata/` on the host and mapped into the container:

| Host path | Container path | Description |
|---|---|---|
| `./userdata/pbgui_data` | `/app/pbgui/data` | PBGui runtime state, bot list, UI settings |
| `./userdata/configs/secrets.toml` | `/app/pbgui/.streamlit/secrets.toml` | Streamlit secrets and optional login password |
| `./userdata/api-keys.json` | `/app/pb7/api-keys.json` | Exchange API credentials |
| `./userdata/historical_data` | `/app/pb7/historical_data` | Downloaded OHLCV market data |
| `./userdata/pb7/configs` | `/app/pb7/configs` | Passivbot v7 live trading configs |
| `./userdata/pb7/backtests` | `/app/pb7/backtests` | Backtest result archives |
| `./userdata/pb7/optimize_results` | `/app/pb7/optimize_results` | Raw optimisation output files |
| `./userdata/pb7/optimize_results_analysis` | `/app/pb7/optimize_results_analysis` | Post-processed optimisation reports |
| `./userdata/pb7/caches` | `/app/pb7/caches` | Cached market data |

***

## Resource Limits

The container is configured with the following default resource limits (adjustable in `docker-compose.yml`):

| Resource | Default limit |
|---|---|
| CPU | 4 cores |
| Memory | 8 GB |

***

## Updating

PBGui and Passivbot v7 can be updated directly from the **PBGui web interface** at `http://localhost:8501` — no terminal access required.

If you need to rebuild the Docker image itself (e.g. after changes to the `Dockerfile`):

```bash
docker compose down
docker compose up -d --build --no-cache
```

> Your `userdata/` directory is never affected by image rebuilds.

***

## Managing

### Stopping the Container

To stop and remove the PBGui-Docker container without losing its data you can run:
```bash
docker compose down
```

To simply pause the container without removing it you can run:
```bash
docker stop pbgui
```

### Starting the Container

To restart the paused container you can run:
```bash
docker start pbgui
```

***

## Contributing

Contributions, bug reports, and suggestions are welcome!

Feel free to open an [Issue](https://github.com/dreamelite96/pbgui-docker/issues) if you have any questions.

***

## Disclaimer

This project is an **independent** Docker setup for [PBGui](https://github.com/msei99/pbgui) by msei99.
It does not redistribute, modify, or include any code from the original PBGui or Passivbot repositories.
The only interaction with those projects is cloning them from GitHub at image build time.

This project, PBGui, and Passivbot are provided "as is", without any warranty of any kind. Automated trading
involves significant financial risk. Neither the authors of this project or the authors of PBGui or Passivbot
are responsible for any financial losses, damages, or missed profits that may result from the use of this
software. Trade at your own risk.

***

## License

The code in this repository is original work released under the **[GNU General Public License v3.0](LICENSE)**.

Copyright © 2026 [@dreamelite96](https://github.com/dreamelite96)

Any use, modification, or redistribution of this project's code requires:
- Attribution to the original author
- Release of derivative works under the same GPL-3.0 license
