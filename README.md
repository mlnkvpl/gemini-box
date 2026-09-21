
# Gemini-Box: Sandboxed Gemini CLI + Browser Automation

A secure, isolated Docker container setup for running Google's official Gemini CLI (`@google/gemini-cli`) paired with live host browser automation via the Chrome DevTools Model Context Protocol (`chrome-devtools-mcp`).

It isolates the agent strictly inside your `~/workdir` projects, shields your host home directory (SSH keys, shell dotfiles, personal credentials), prevents root file-permission issues, and bridges safely to your host's Google Chrome instance for autonomous web tasks.

---

## Architecture & Security Boundary

* **Host Filesystem Isolation:** The agent only accesses `~/workdir`. It cannot read host paths such as `~/.ssh`, `~/.aws`, or `~/.bashrc`.
* **Clean User Permissions:** Runs mapped to your host's non-root `UID:GID`, ensuring files created or modified by the agent remain editable on your host.
* **Persistent Configuration:** Authentication tokens, project history, and MCP server configurations persist in `~/gemini/.config` (mapped to `/home/node/.gemini`).
* **Safe Host Browser Bridge:** Controls your host Chrome instance over the Chrome DevTools Protocol (CDP). A lightweight `socat` bridge forwards container traffic (`172.17.0.1:9223`) to Chrome's local loopback listener (`127.0.0.1:9222`), bypassing Chrome's DNS-rebinding security checks while keeping the container sandboxed.
* **Scoped Docker access (Docker-outside-of-Docker):** The agent can run `docker`/`docker compose` — needed to actually build/run/test the projects under `~/workdir` — without a raw mounted socket or a nested daemon. A `docker-socket-proxy` sidecar holds the real `/var/run/docker.sock` and exposes only a filtered subset of the Docker API (containers/images/networks/volumes/build/exec, read+write; swarm/secrets/plugins/system left denied) over `DOCKER_HOST`. Same setup as `claude-box` — see [Docker access](#docker-access-docker-outside-of-docker) below, including the caveat that this narrows but doesn't eliminate the risk.
* **Host-mirrored workspace path:** `~/workdir` is bind-mounted at the *same absolute path* inside the container (`$HOME/workdir`), not a convenience alias like `/workspace`. Docker-outside-of-Docker means `docker compose` run inside the agent is executed by the *host's* daemon, which resolves any relative bind mount in a compose file (e.g. `./projects/api:/var/www/html`) against its own filesystem — a mismatched path here silently mounts the wrong (or an empty) host directory instead of your real project files.

---

## Directory Structure

```text
~/gemini/
├── .config/
│   └── settings.json    # MCP server configuration & auth type
├── .env                 # API Key and CLI shortcut name
├── cli.sh               # Shell installer, Chrome launcher, builder, and runner
├── docker-compose.yml   # gemini + docker-socket-proxy services, user mapping, volume mounts, extra_hosts
├── Dockerfile           # Node 20-slim + Gemini CLI + dev tools + docker CLI (DooD client)
└── README.md            # Documentation
```

---

## Setup & Reproduction Steps

### 1. Prerequisites

* Docker and Docker Compose v2 (`docker compose`) installed on Ubuntu.
* `socat` and Google Chrome installed on your host system:
```bash
sudo apt update && sudo apt install -y socat google-chrome-stable
```


* A Gemini API key from [Google AI Studio](https://aistudio.google.com).
* Workspace directory:
```bash
mkdir -p ~/workdir
```



---
### 2. File Configurations

Create the setup directory:

```bash
mkdir -p ~/gemini/.config
cd ~/gemini
chmod 700 .config
```

#### `Dockerfile`

```dockerfile
FROM node:20-slim

# Install standard utilities that code agents rely on.
# jq/ripgrep/shellcheck/python3+python3-yaml: diagnostic/verification tools.
# libnss3-tools: mkcert needs it to cover Firefox's own trust store too.
# gnupg: needed for the PHP apt repo signing key below.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates procps \
        jq ripgrep shellcheck python3 python3-yaml libnss3-tools gnupg \
    && rm -rf /var/lib/apt/lists/*

# PHP 8.3 CLI + Composer — matches this workspace's actual runtime version,
# so `php -l`, `composer validate`, etc. run against the same PHP the real
# app deploys on, not whatever Debian's default happens to ship.
RUN curl -sSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/php.gpg \
    && . /etc/os-release \
    && echo "deb https://packages.sury.org/php/ ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/php.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        php8.3-cli php8.3-mbstring php8.3-xml php8.3-curl php8.3-sqlite3 php8.3-pgsql \
    && rm -rf /var/lib/apt/lists/* \
    && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# mkcert — for exercising any locally-trusted-TLS setup in the workspace
# instead of just reading the script and trusting it.
RUN curl -sSL "https://dl.filippo.io/mkcert/latest?for=linux/amd64" -o /usr/local/bin/mkcert \
    && chmod +x /usr/local/bin/mkcert

# --- Docker CLI (client only — Docker-outside-of-Docker) ---
# No daemon runs in this container. `docker`/`docker compose` here talk to
# docker-socket-proxy (see docker-compose.yml) over DOCKER_HOST, not to a raw
# mounted socket and not to a nested dockerd. The proxy holds the real
# /var/run/docker.sock and exposes only a scoped subset of the Docker API —
# see docker-compose.yml for the exact grants.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && . /etc/os-release \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Install Gemini CLI and official Chrome DevTools MCP server globally
RUN npm install -g @google/gemini-cli chrome-devtools-mcp

# Fix: the entrypoint runs as the `node` user at runtime but this global
# install happens as root at build time — this breaks the CLI's
# self-updater with a permissions error if it self-updates the same way.
# Hand the install tree to `node` so it can update itself.
RUN chown -R node:node /usr/local/lib/node_modules /usr/local/bin

# Fallback only — docker-compose.yml's `working_dir:` overrides this at
# runtime to the host-mirrored path (see that file for why).
WORKDIR /workspace

ENTRYPOINT ["gemini"]
```

#### `docker-compose.yml`

```yaml
services:
  # Docker-outside-of-Docker access, scoped. Holds the real host socket
  # itself; `gemini` never sees it directly — it only talks to this proxy
  # over DOCKER_HOST. Grants write access to containers/images/networks/
  # volumes/build/exec; everything else (swarm, secrets, plugins, system,
  # nodes, services, tasks, configs) stays at the proxy's default-deny.
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: gemini-box-docker-proxy
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - CONTAINERS=1
      - IMAGES=1
      - NETWORKS=1
      - VOLUMES=1
      - BUILD=1
      - EXEC=1
      - POST=1

  gemini:
    build: .
    user: "${UID:-1000}:${GID:-1000}"
    # Must match the host-side volume path exactly — see the note in
    # "Architecture & Security Boundary" above (Host-mirrored workspace path).
    # cli.sh exports HOST_WORKDIR="$HOME/workdir" before every invocation.
    working_dir: ${HOST_WORKDIR}
    stdin_open: true
    tty: true
    depends_on:
      - docker-socket-proxy
    extra_hosts:
      - "host.docker.internal:172.17.0.1"
    volumes:
      - ${HOST_WORKDIR}:${HOST_WORKDIR}
      - ./.config:/home/node/.gemini
    environment:
      - GEMINI_API_KEY=${GEMINI_API_KEY}
      - CHROME_CDP_URL=http://172.17.0.1:9223
      - DOCKER_HOST=tcp://docker-socket-proxy:2375
```

#### `.config/settings.json`

Configures the agent to use API key authentication and enables the slim browser toolset to minimize token consumption:

```json
{
  "selectedAuthType": "gemini-api-key",
  "mcpServers": {
    "chrome-browser": {
      "command": "chrome-devtools-mcp",
      "args": [
        "--browser-url=http://172.17.0.1:9223",
        "--slim"
      ]
    }
  }
}

```

#### `.env`

```ini
GEMINI_API_KEY="your-gemini-api-key-here"
CLI_NAME="gemini-box"

```

#### `cli.sh`

```bash
#!/usr/bin/env bash

GEMINI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$GEMINI_DIR/.env" ]; then
  CUSTOM_CLI=$(grep -E '^CLI_NAME=' "$GEMINI_DIR/.env" | cut -d '=' -f2- | tr -d '"'\'' ')
fi
CMD="${CUSTOM_CLI:-gemini-box}"

INSTALL_LINE="[ -f \"$GEMINI_DIR/cli.sh\" ] && source \"$GEMINI_DIR/cli.sh\" env"

case "$1" in
  install)
    if grep -Fxq "$INSTALL_LINE" "$HOME/.bashrc"; then
      echo "[✓] Hook already present in ~/.bashrc"
    else
      echo "" >> "$HOME/.bashrc"
      echo "# Gemini CLI sandbox hook" >> "$HOME/.bashrc"
      echo "$INSTALL_LINE" >> "$HOME/.bashrc"
      echo "[✓] Installed hook into ~/.bashrc. Run: source ~/.bashrc"
    fi
    ;;

  uninstall)
    sed -i "\|$INSTALL_LINE|d" "$HOME/.bashrc"
    echo "[✓] Removed hook from ~/.bashrc."
    ;;

  build)
    echo "Building Gemini container..."
    HOST_WORKDIR="$HOME/workdir" GID=$(id -g) docker compose -f "$GEMINI_DIR/docker-compose.yml" build
    ;;

  # Launch isolated Chrome instance and socat forwarder
  chrome)
    echo "Launching host Chrome with remote debugging on port 9222..."
    mkdir -p /tmp/chrome-agent-profile
    google-chrome \
      --remote-debugging-port=9222 \
      --user-data-dir=/tmp/chrome-agent-profile \
      --no-first-run \
      --no-default-browser-check > /dev/null 2>&1 &

    # Forward docker0 bridge traffic (port 9223) to host localhost (port 9222)
    pkill -f "socat.*9223" || true
    sleep 1
    socat TCP-LISTEN:9223,fork,bind=0.0.0.0 TCP:127.0.0.1:9222 > /dev/null 2>&1 &
    echo "[✓] Chrome running on 9222, bridged to Docker on 172.17.0.1:9223."
    ;;

  env)
    eval "
    ${CMD}() {
      case \"\$1\" in
        chrome)
          \"$GEMINI_DIR/cli.sh\" chrome
          ;;
        build)
          \"$GEMINI_DIR/cli.sh\" build
          ;;
        *)
          HOST_WORKDIR=\"\$HOME/workdir\" GID=\$(id -g) docker compose -f \"$GEMINI_DIR/docker-compose.yml\" run --rm gemini \"\$@\"
          ;;
      esac
    }
    "
    ;;

  *)
    HOST_WORKDIR="$HOME/workdir" GID=$(id -g) docker compose -f "$GEMINI_DIR/docker-compose.yml" run --rm gemini "$@"
    ;;
esac

```

Make the script executable:

```bash
chmod +x ~/gemini/cli.sh
```

---

### 3. Firewall Configuration (Ubuntu UFW)

Allow the Docker bridge subnet to access the forwarder port:

```bash
sudo ufw allow in on docker0 to any port 9223 proto tcp
```

---

### 4. Build & Install Hook

1. Build the Docker container image:
```bash
~/gemini/cli.sh build
```


2. Register the terminal alias into `~/.bashrc`:
```bash
~/gemini/cli.sh install
source ~/.bashrc
```


---

## Docker access (Docker-outside-of-Docker)

The agent can run `docker`/`docker compose` — needed to actually build, start, and test
Dockerized projects under `~/workdir`, not just edit their config files. No manual setup
step is required; it works automatically once you `~/gemini/cli.sh build` and run
normally.

**How it works:** a `docker-socket-proxy` sidecar (see `docker-compose.yml`) mounts the
real `/var/run/docker.sock` and re-exposes a *filtered* subset of the Docker API over
`DOCKER_HOST=tcp://docker-socket-proxy:2375`. The `gemini` container never sees the raw
socket itself. Enabled: containers, images, networks, volumes, build, exec — read and
write. Left at the proxy's default-deny: swarm, secrets, plugins, system info, nodes,
services, tasks, configs. Same setup as `claude-box` — each agent has its own proxy
container, but both ultimately talk to the one host daemon.

**What this means in practice:**
- Because the proxy talks to the *same* host daemon your own `docker`/`docker compose`
  does, everything is shared, not duplicated — if the agent runs `docker compose up` on
  a project, you'll see those same running containers with `docker ps` on your host, and
  running `docker compose up` yourself on the same compose file converges to the same
  state rather than creating a second copy.
- **This is not a hard security boundary, just a narrower one than a raw socket mount.**
  The proxy restricts *which* Docker API categories are reachable, but doesn't inspect
  *parameters within* an allowed call — a container-create request through the enabled
  `containers`+`build` categories could still, in principle, request `--privileged` or a
  host bind mount. Closing that specific gap needs a policy/admission-control layer in
  front of the proxy, which isn't set up here. Treat this as convenience-oriented
  isolation, not a multi-tenant-grade sandbox.
- The workspace is mounted at the **same absolute path** on both sides
  (`$HOME/workdir` on the host, mirrored inside the container) instead of a friendly
  alias like `/workspace` — required so relative bind mounts inside a project's own
  `docker-compose.yml` (e.g. `./projects/api:/var/www/html`) resolve correctly against
  the *host's* filesystem, since Docker-outside-of-Docker means the host daemon — not
  this container — is what actually creates those mounts.

---

## Workflow & Usage

### 1. Start the Host Browser Bridge

Before initiating browser automation, run the Chrome launcher on your host:

```bash
~/gemini/cli.sh chrome
```

### 2. Launch Gemini CLI

Start an interactive agent session from any working directory:

```bash
gemini-box
```

### 3. Model Recommendation & Quotas

For tool-calling and web automation on the free tier, use Flash models to avoid hitting strict daily limits:

```text
/model gemini-3.5-flash
```

### 4. Example Browser Prompts

* "Navigate to google.com and search for the latest news on Linux kernel releases."
* "Navigate to https://news.ycombinator.com and extract the titles and URLs of the top 5 submissions."

---

## Troubleshooting

* **Permission denied (`EACCES: /home/node/.gemini/...`):**
If files in `.config` were created as `root`, reset ownership to your current host user:
```bash
sudo chown -R $(id -u):$(id -g) ~/gemini/.config
chmod 700 ~/gemini/.config
```


* **Chrome connection hangs or times out:**
Verify that both Chrome and the `socat` bridge are listening:
```bash
ss -tulpn | grep -E '9222|9223'
```


Test the endpoint directly from inside the container:
```bash
docker compose -f ~/gemini/docker-compose.yml run --rm --entrypoint curl gemini -m 3 -s http://172.17.0.1:9223/json/version
```


* **`Host header is specified and is not an IP address or localhost`:**
Ensure `settings.json` points directly to `http://172.17.0.1:9223` instead of domain hostnames like `host.docker.internal` to prevent Chrome's internal DNS-rebinding security rejection.

* **`docker`/`docker compose` inside the agent fails with a connection error:**
Confirm the proxy sidecar is actually running: `docker compose -f ~/gemini/docker-compose.yml ps docker-socket-proxy`. If it's not, `depends_on` should have started it automatically on the last `gemini-box` invocation — try `~/gemini/cli.sh build` again, or bring it up directly with `docker compose -f ~/gemini/docker-compose.yml up -d docker-socket-proxy`.

* **A project's `docker compose up` starts containers, but a bind-mounted directory is empty/wrong inside them:**
`HOST_WORKDIR` wasn't set to the same path on both sides of a volume mount — check `cli.sh`'s invocations still export `HOST_WORKDIR="$HOME/workdir"` before every `docker compose` call, and that `docker-compose.yml`'s `working_dir`/volume lines still reference `${HOST_WORKDIR}`, not a hardcoded alias like `/workspace`. See [Docker access](#docker-access-docker-outside-of-docker) for why this has to match exactly.
