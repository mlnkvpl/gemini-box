
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
├── scripts/
│   └── help.sh           # `help`/`--help`/`-h` command text, sourced by cli.sh
├── docs/
│   └── INSTRUCTION.md    # Full setup/reproduction steps (see Setup below)
├── docker-compose.yml   # gemini + docker-socket-proxy services, user mapping, volume mounts, extra_hosts
├── Dockerfile           # Node 20-slim + Gemini CLI + dev tools + docker CLI (DooD client)
└── README.md            # Documentation
```

---

## Setup

Full from-scratch setup — prerequisites, exact file contents, firewall config, and the
build/install commands — lives in [`docs/INSTRUCTION.md`](docs/INSTRUCTION.md).

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
