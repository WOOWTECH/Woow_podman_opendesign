#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the product's real rootless Podman entrypoint. This is intentionally
# separate from the faster Docker managed-runtime smoke: it checks keep-id,
# read-only-root operation, the native daemon/Paseo bridge, and graceful stop.
image=${1:?usage: podman-native-lifecycle.sh IMAGE}
run_id=${GITHUB_RUN_ID:-local}-$$
container="woow-od-native-${run_id}"
volume="woow-od-native-data-${run_id}"

cleanup() {
  podman rm --force --ignore "$container" >/dev/null 2>&1 || true
  podman volume rm --force "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

[[ $(podman info --format '{{.Host.Security.Rootless}}') == true ]]
podman volume create "$volume" >/dev/null
podman run -d \
  --pull=never \
  --name "$container" \
  --network none \
  --userns=keep-id:uid=1001,gid=1001 \
  --user 1001:1001 \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,size=1g,mode=1777 \
  --volume "$volume:/app/.od" \
  --env WOOW_OD_PASEO=on \
  --env OD_ALLOWED_ORIGINS=https://localhost:27457 \
  --env OPENDESIGN_PASEO_ORIGIN=https://localhost:27457 \
  "$image" >/dev/null

ready=0
for _ in $(seq 1 120); do
  [[ $(podman inspect --format '{{.State.Running}}' "$container") == true ]] || break
  if podman exec "$container" curl -fsS -o /dev/null http://127.0.0.1:7457/api/health \
    && podman exec "$container" curl -fsS -o /dev/null http://127.0.0.1:7460/healthz \
    && podman exec "$container" node --input-type=module -e '
      try {
        const response=await fetch("http://127.0.0.1:7460/api/paseo-bridge",{signal:AbortSignal.timeout(3000)});
        const state=await response.json();
        if(!response.ok||!state.desiredEnabled||!state.daemon?.owned||!state.daemon?.reachable||!state.onboarding?.initialized||["running","error"].includes(state.operation?.status))process.exit(1);
      } catch { process.exit(1); }
    '; then
    ready=1
    break
  fi
  sleep 2
done
[[ $ready == 1 ]] || { echo 'native Podman health timeout' >&2; exit 1; }
[[ $(podman exec "$container" id -u) == 1001 ]]
[[ $(podman exec "$container" cat /proc/1/comm) == tini ]]
if podman exec "$container" touch /agent-connect-root-must-be-read-only 2>/dev/null; then
  echo 'native Podman root filesystem must be read-only' >&2
  exit 1
fi

podman exec "$container" node --input-type=module -e '
  import {readFile} from "node:fs/promises";
  import {verifyBundledInstallation} from "/opt/opendesign-paseo/host/standalone.mjs";
  import {runtimeReady} from "/opt/opendesign-paseo/vendor/pi-paseo/src/runtime-layout.mjs";
  const launcher="/app/plugins/_official/woow/woow-paseo";
  const manifest=JSON.parse(await readFile(`${launcher}/open-design.json`, "utf8"));
  const pkg=JSON.parse(await readFile("/opt/opendesign-paseo/package.json", "utf8"));
  if(manifest.title!=="Agent Connect"||manifest.version!==pkg.version)process.exit(1);
  if(!verifyBundledInstallation(launcher,"/opt/opendesign-paseo"))process.exit(1);
  if(!runtimeReady({runtimeDir:"/opt/opendesign-paseo/managed-runtime"}))process.exit(1);
'

# podman stop sends SIGTERM through tini to the product supervisor. A successful
# stop and a stopped state prove the normal lifecycle path; the trap owns cleanup.
podman stop --time 45 "$container" >/dev/null
[[ $(podman inspect --format '{{.State.Running}}' "$container") == false ]]
[[ $(podman inspect --format '{{.State.OOMKilled}}' "$container") == false ]]
exit_code=$(podman inspect --format '{{.State.ExitCode}}' "$container")
[[ $exit_code == 0 || $exit_code == 143 ]]
cleanup
if podman container exists "$container" || podman volume exists "$volume"; then
  echo 'owned native Podman test resources remain' >&2
  exit 1
fi
printf '{"rootless":true,"uid":1001,"tiniPid1":true,"readOnlyRoot":true,"nativeHealth":true,"bridgeHealth":true,"bakedRuntimeReady":true,"managedDaemonReachable":true,"nativeOnboardingInitialized":true,"normalStop":true,"ownedResourcesCleaned":true,"exitCode":%s}\n' "$exit_code"
