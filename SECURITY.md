# Security Policy

## Supported Versions

Only the latest version of `pbgui-docker` on the `main` branch receives security fixes.
Older tags or forks are not maintained.

| Version | Supported |
|---------|-----------|
| `main` (latest) | ✅ |
| Older tags | ❌ |

---

## Reporting a Vulnerability

If you discover a security vulnerability in **pbgui-docker**, please **do not open a public GitHub issue**.

Instead, report it privately via **GitHub private vulnerability reporting**: [Security → Report a vulnerability](https://github.com/dreamelite96/pbgui-docker/security/advisories/new)

Please include as much of the following information as possible to help reproduce and assess the issue:

- A description of the vulnerability and its potential impact
- Steps to reproduce (commands, config snippets, environment)
- Affected component (`Dockerfile`, `entrypoint.sh`, `install.sh`, `docker-compose.yml`, …)
- Any suggested mitigation or fix

You can expect an initial response within **72 hours** and a status update within **7 days**.

---

## Scope

This policy covers the **pbgui-docker** repository only — i.e., the files in this repository:
`Dockerfile`, `docker-compose.yml`, `entrypoint.sh`, `install.sh`, and related configuration.

**Out of scope** (report to the respective upstream projects):

| Component | Repository |
|-----------|-----------|
| PBGui (Streamlit UI) | [msei99/pbgui](https://github.com/msei99/pbgui) |
| Passivbot v7 | [enarjord/passivbot](https://github.com/enarjord/passivbot) |

---

## Security Design

The following hardening measures are built into this project.

### Non-root container execution

The container process runs as a dedicated `pbgui` system user (non-root).
The user's UID and GID are configured at build time via `PBGUI_UID` / `PBGUI_GID`
build arguments and must match the host user that owns the bind-mounted volumes.
This ensures that files written inside the container are accessible on the host
without needing `chmod 777` or running as root.

### Dropped Linux capabilities

The container drops **all** Linux capabilities by default and re-adds only the
minimum required for correct operation:

```yaml
cap_drop:
  - ALL
cap_add:
  - DAC_OVERRIDE
  - FOWNER
```

`no-new-privileges: true` prevents any process inside the container from gaining
additional privileges via `setuid`/`setgid` executables.

### Multi-stage Docker build

A two-stage `Dockerfile` is used:

- **Stage 1 (builder)**: installs the full build toolchain (Rust, `build-essential`,
  deadsnakes PPA, `pip` build dependencies). None of this tooling reaches the
  final image.
- **Stage 2 (runtime)**: receives only the compiled artifacts (`venv_pb7`,
  `venv_pbgui`, application source) via `COPY --from=builder`. The runtime image
  does not contain compilers, build headers, or apt package lists.

### Sudo scope restriction

The `pbgui` user is granted `sudo` access exclusively for two `apt`/`apt-get`
commands, which are required by PBGui's internal Ansible update playbooks:

```
pbgui ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt
```

No other commands are whitelisted. The sudoers drop-in file is set to mode `440`.

### Container isolation

| Setting | Value |
|---------|-------|
| `privileged` | `false` |
| `stdin_open` | `false` |
| `tty` | `false` |
| `no-new-privileges` | `true` |
| Network | isolated bridge (`pbgui-net`) |
| Watchtower auto-update | disabled (`com.centurylinklabs.watchtower.enable=false`) |

### Resource limits

Default CPU and memory limits prevent runaway processes from exhausting host
resources:

| Resource | Default |
|----------|---------|
| CPU | 4 cores |
| Memory | 8 GB |

Limits are configurable in `.env` / `docker-compose.yml`.

### Secret and credential handling

- Exchange API keys are stored in `userdata/api-keys.json`, which is bind-mounted
  into the container and **never baked into the image**.
- The optional Web UI password is stored in `userdata/streamlit/secrets.toml`,
  also bind-mounted and excluded from the image and from version control via
  `.gitignore` / `.dockerignore`.
- The `.env` file (which contains `PBGUI_UID`, `PBGUI_GID`, port mappings, and
  resource limits) is likewise excluded from version control.

### Healthcheck

A built-in Docker healthcheck polls the Streamlit endpoint every 30 seconds
(`GET http://127.0.0.1:8501/healthz`). The check always targets the fixed
internal container port, regardless of the host-side port mapping.

---

## Recommendations for Operators

- **Do not expose ports 8501 / 8000 to the public internet** without placing a
  reverse proxy (e.g. Nginx, Caddy, Traefik) with TLS in front of them.
- **Enable the Web UI password** during installation or by editing
  `userdata/streamlit/secrets.toml` — the UI has no authentication by default.
- **Keep Docker and the host OS up to date.** The base image (`ubuntu:24.04`) and
  runtime packages should be patched regularly by rebuilding the image:
  ```bash
  docker compose build --no-cache
  docker compose up -d
  ```
- **Review your exchange API key permissions.** Passivbot v7 requires trading
  permissions; it does not require withdrawal permissions. Restrict keys
  accordingly on your exchange dashboard.

---

## Disclosure Policy

Security fixes will be released as soon as a patch is ready.
A [GitHub Security Advisory](https://github.com/dreamelite96/pbgui-docker/security/advisories)
will be published after the fix is available, crediting the reporter (unless
they prefer to remain anonymous).

---

## License

This security policy applies to code released under the
[GNU General Public License v3.0](LICENSE).
Copyright © 2026 [@dreamelite96](https://github.com/dreamelite96)
