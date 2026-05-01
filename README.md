# PBGui-Docker

[![Docker](https://img.shields.io/badge/Docker-container-2496ED?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Python](https://img.shields.io/badge/Python-3.12-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://www.python.org/)

<a href="https://www.buymeacoffee.com/dreamelite96" target="_blank">
  <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" width="200" height="50">
</a>

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Requirements](#requirements)
- [Project Structure](#project-structure)
- [Installation](#installation)
- [Configuration](#configuration)
- [Accessing the Interface](#accessing-the-interface)
- [Volumes & Persistent Data](#volumes--persistent-data)
- [Resource Limits](#resource-limits)
- [Updating](#updating)
- [Managing](#managing)
- [Contributing](#contributing)

## Overview

**PBGui-Docker** provides a ready-to-use Docker setup to deploy [PBGui](https://github.com/msei99/pbgui) by msei99 — a Streamlit-based web GUI for managing [Passivbot v7](https://github.com/enarjord/passivbot) trading bot instances — inside an isolated Docker container.

The image is built on **Ubuntu 24.04 LTS** and bundles the full dependency stack at build time:

- **Python 3.12** (via the deadsnakes PPA)
- **Rust toolchain** (required to compile `passivbot-rust`, the performance-critical Rust extension of Passivbot v7)
- **Ansible** (used internally by PBGui for remote bot management)
- Two isolated Python virtual environments: one for PBGui (`venv_pbgui`) and one for Passivbot v7 (`venv_pb7`)


## Features

- ⚡ **One-command setup** — no manual Python, Rust, or Ansible installation required
- 🐳 **Cross-platform** — works on Linux, macOS, and Windows via Docker
- 💾 **Persistent volumes** — all data, configs, backtests, and API keys survive container restarts
- 🔄 **Re-runnable setup script** — can be safely run multiple times; never overwrites existing credentials
- 🔒 **Security-hardened** — runs with dropped Linux capabilities and `no-new-privileges`
- 🩺 **Healthcheck built-in** — Docker automatically monitors the Streamlit interface
- 🖥️ **TrueNAS SCALE compatible** — `install.sh` detects TrueNAS environments and adapts accordingly


## Requirements

- [Docker](https://docs.docker.com/get-docker/) v20.10+
- [Docker Compose](https://docs.docker.com/compose/install/) v2.0+
- A valid exchange API key (Bybit, Bitget, OKX, Binance and many others) for Passivbot v7


## Project Structure

```
pbgui-docker/
├── Dockerfile              # Container image definition (Ubuntu 24.04 LTS + Python 3.12 + Rust)
├── docker-compose.yml      # Service orchestration with volumes, ports, and security config
├── install.sh              # Installation script
├── README.md               # This file
└── userdata/               # Created by the installer — all persistent data lives here
    ├── api-keys.json       # Exchange API credentials
    ├── configs/            # secrets.toml and other app-level config
    ├── pbgui_data/         # PBGui runtime state, bot list, UI settings
    ├── historical_data/    # Downloaded OHLCV market data
    └── pb7/                # Passivbot v7 configs, backtests, and optimisation results
```

***

## Installation

`install.sh` handles the entire setup: checks prerequisites, clones the repository, creates the directory structure, guides you through initial configuration, builds and starts the Docker container, and verifies that the service is healthy.

### System Requirements

|  | Minimum | Recommended |
|---|---|---|
| CPU | 2 cores | 4+ cores |
| RAM | 4GB | 8GB+ |
| Disk | 20GB free | 50GB+ free |
| OS | Any Linux with Docker | Ubuntu Server 26.04 LTS / TrueNAS |

> **Note:** The first build compiles a Rust extension (`passivbot-rust`) and may take **5-10 minutes** depending on your hardware. Subsequent builds are much faster thanks to Docker layer caching.

**Required software:**
- [Docker](https://docs.docker.com/get-docker/) v20.10+
- [Docker Compose](https://docs.docker.com/compose/install/) v2.0+ (plugin, not standalone)
- [Git](https://git-scm.com/install/)

### One-Command Install

```bash
curl -fsSL https://raw.githubusercontent.com/dreamelite96/pbgui-docker/main/install.sh -o /tmp/install.sh && sudo bash /tmp/install.sh && sudo rm /tmp/install.sh
```

The script can also be run locally from an already-cloned repository:

```bash
sudo ./install.sh
```

### What the Installer Asks

The installer walks you through a short interactive setup. All prompts have a default value — press Enter to accept it.

1. **Install directory** — base path where `pbgui-docker/` will be created
   - Default on Linux: `/opt/docker`
   - Default on TrueNAS Scale: `/mnt/tank/docker`
   - On TrueNAS, the installer can automatically create a ZFS dataset at the chosen path

2. **Default exchange** — pre-populates `api-keys.json` with the exchange name *(default: `binance`)*; supported values include `bybit`, `bitget`, `gateio`, `hyperliquid`, `okx`, `kucoin`, `bingx`. Real API credentials are added later from the Web UI.

3. **Password protection** — optionally set a login password for the Web UI. Can be enabled or changed at any time from the Web UI or by editing `userdata/configs/secrets.toml`.

### First-Time Setup

Once the installer reports **PBGui is up and running**:

1. Open the Web UI at **http://\<your-host-ip\>:8501**
2. Add your exchange **Wallet Address** and **Private Key** under **System → API-Keys**
3. Add your **CoinMarketCap API key** under **System → API-Keys**
4. You're ready — create your first bot instance under **PBv7 → Run**

***

## Configuration

### Configure your API keys

API keys can be configured directly from the **PBGui web interface** at `http://<your-host-ip>:8501` — no manual file editing required.

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

The PBGui-Docker installer will ask you to set a password for the Web UI directly, but you can also set it from the **PBGui web interface** at `http://<your-host-ip>:8501`.

Alternatively, you can enable it manually by editing `userdata/configs/secrets.toml` and adding:

```toml
password = "your-strong-password"
```

***

## Accessing the Interface

| Interface | URL |
|---|---|
| WebUI (Streamlit) | http://\<your-host-ip\>:8501 |
| New WebUI (FastAPI) | http://\<your-host-ip\>:8000 |

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

### Update PBGui / Passivbot v7
PBGui and Passivbot v7 can be updated directly from the **PBGui web interface** at `http://<your-host-ip>:8501` — no terminal access required.

### Rebuild the Docker image
If you made changes to the `Dockerfile` or need a fresh image build:
```bash
docker compose down
docker compose build --no-cache
docker compose up -d
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

Feel free to open an [Issue](https://github.com/dreamelite96/pbgui-docker/issues) if you find a bug or have any questions, or submit a [Pull Request](https://github.com/dreamelite96/pbgui-docker/pulls) if you'd like to contribute code or improvements.

If you find this project useful and want to support its development, consider buying me a coffee — it helps keep the project alive and motivates future updates!

<a href="https://www.buymeacoffee.com/dreamelite96" target="_blank">
  <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me a Coffee" width="200" height="50">
</a>

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
