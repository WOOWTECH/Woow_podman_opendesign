# Open Design Pi Runtime Migration Implementation Plan

> **Superseded — design history only.** This plan describes the podman-compose, host-network layout
> that was replaced in v3.0.0 by the Quadlet + systemd deployment (`quadlet/`, `scripts/install.sh`).
> The Pi runtime decisions it records still hold; the deployment mechanics in it do not. It is kept
> for the reasoning, not as instructions. See the README for the current deployment.

**Goal:** Remove OpenCode execution capability and host state from A host, then make Open Design detect and launch Pi 0.83.0 through its native RPC runtime.

**Architecture:** Keep Open Design's built-in Pi runtime adapter and install the matching Pi CLI in the custom Open Design image. A small launcher gives only Pi subprocesses the shared Pi data directory and HOME, while the Open Design daemon retains its existing HOME so other runtimes remain intact. Share the existing external `pi-agent-data` volume read-write for Pi auth, settings, sessions, and token refresh; preserve the static `opencode-ai` template assets already baked into the upstream image.

**Tech Stack:** Rootless Podman, podman-compose, Alpine Linux, Node.js/npm, Open Design daemon, Pi JSON-RPC.

---

### Task 1: Capture rollback state and a red-capable baseline

**Files:**
- Create remotely: `~/.local/state/open-design/backups/<timestamp>/deploy.tar.gz`
- Create remotely: `~/.local/state/open-design/backups/<timestamp>/opencode-state.tar.gz`
- Create remotely: `~/Desktop/open-design/deploy/docs/plans/2026-08-28-open-design-pi-runtime-migration.md`

**Step 1:** Query authenticated `GET http://127.0.0.1:7457/api/agents` from inside `open-design` and assert Pi exists with `available=false`.

**Step 2:** Record current container/image IDs, health endpoints, OpenCode paths, and Open Design deployment checksums without printing secrets.

**Step 3:** Create mode-0700 backup directory and mode-0600 archives for deployment files and every existing OpenCode state path.

**Step 4:** Tag the current Open Design image with a timestamped rollback tag.

### Task 2: Package Pi CLI for Open Design

**Files:**
- Modify remotely: `~/Desktop/open-design/deploy/Dockerfile.full`
- Create remotely: `~/Desktop/open-design/deploy/pi-od`

**Step 1:** Add `npm install -g --omit=dev @earendil-works/pi-coding-agent@0.83.0` to the image and fail the build unless `pi --version` reports `0.83.0`.

**Step 2:** Add `/usr/local/bin/pi-od`, which exports `HOME=/data/pi-agent/home`, `PI_CODING_AGENT_DIR=/data/pi-agent`, `PI_TELEMETRY=0`, and `PI_SKIP_VERSION_CHECK=1`, then execs `/usr/local/bin/pi` with unchanged arguments.

**Step 3:** Build `localhost/open-design-full:latest` while the current container remains running.

**Step 4:** Run an isolated image smoke test for the Pi version and RPC `get_state` response.

### Task 3: Replace OpenCode mounts with Pi runtime integration

**Files:**
- Modify remotely: `~/Desktop/open-design/deploy/docker-compose.podman.yml`

**Step 1:** Remove `/mnt/host-opencode` from PATH.

**Step 2:** Remove the OpenCode binary, auth, data, and state mounts.

**Step 3:** Add `PI_BIN=/usr/local/bin/pi-od`, Pi data-directory environment variables, and the existing external volume `pi-agent-data:/data/pi-agent`.

**Step 4:** Validate the rendered Compose configuration and verify it contains no OpenCode host mount or secret value.

**Step 5:** Recreate only the Open Design daemon, preserving the nginx sidecar and loopback binding.

### Task 4: Verify migration before deleting host state

**Files:** None.

**Step 1:** Wait for the Open Design container healthcheck and verify daemon `:7457` and nginx `:7456` health endpoints return HTTP 200.

**Step 2:** Re-run the original `/api/agents` loop and assert Pi is `available=true` and OpenCode is `available=false`.

**Step 3:** Execute Pi RPC `get_state` and `get_available_models` through the same launcher and assert valid JSON responses. Do not run an LLM prompt because no provider is configured.

**Step 4:** Confirm static paths containing the `opencode-ai` design template remain in the image.

**Step 5:** Confirm the Pi web UI remains loopback-only on `127.0.0.1:30142`, returning 401 without Basic Auth and 200 with credentials loaded from the protected credentials file.

### Task 5: Delete OpenCode host execution state and run final acceptance

**Files to remove remotely after Task 4 passes:**
- `~/.cache/opencode`
- `~/.config/opencode`
- `~/.local/share/opencode`
- `~/.local/state/opencode`
- `~/.opencode`
- `~/.opencode-state`

**Step 1:** Remove only the listed paths; do not touch static assets inside the Open Design image.

**Step 2:** Search host executables, running processes, Podman objects, user services, Compose, and live mounts for remaining OpenCode execution capability.

**Step 3:** Re-run all Task 4 acceptance checks after deletion.

**Step 4:** Report backup and rollback image locations, changed files, commands run, validation output, and the residual risk that actual model inference remains untested until a provider is configured.

### Rollback

1. Restore the deployment archive into `~/Desktop/open-design/deploy/`.
2. Retag the timestamped pre-migration image as `localhost/open-design-full:latest`.
3. Recreate `open-design` with podman-compose.
4. Restore OpenCode state archive only if rollback explicitly requires OpenCode execution capability.
