# shellcheck shell=bash
# tests/dryrun.local.sh: OpenDesign-specific assertions. Sourced at the end of tests/dryrun.sh
# (vendored), which provides run_variant, render_variant, $WORK, $REPO, $base, $failures.
# shellcheck disable=SC2154 # the variables above are defined by tests/dryrun.sh

check() { # check <description> <command...>
  if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}
has_line() { grep -qxF -- "$3" "$WORK/$1/out/$2"; }

check "example publishes nginx's port on 127.0.0.1" has_line example open-design.container 'PublishPort=127.0.0.1:7456:7456'
check "example uses the default limits" has_line example open-design.container 'PodmanArgs=--memory=2g --cpus=2'
check "BIND=all and a moved port are rendered" has_line fixture-lan open-design.container 'PublishPort=27456:7456'
check "the daemon's limits are rendered per host" has_line fixture-lan open-design.container 'PodmanArgs=--memory=1536m --cpus=1.5'
# The rules are applied per file: rendering the daemon's limits must not touch the nginx unit.
check "the nginx limits are left alone" has_line fixture-lan open-design-nginx.container 'PodmanArgs=--memory=128m --cpus=0.5'
check "the pids limits podman-compose dropped are in the units" bash -c \
  "grep -qx 'PidsLimit=512' '$WORK/example/out/open-design.container' && grep -qx 'PidsLimit=128' '$WORK/example/out/open-design-nginx.container'"
check "nginx joins the daemon's network namespace" has_line example open-design-nginx.container 'Network=container:open-design'
check "nginx is bound to the daemon's lifecycle" bash -c \
  "grep -qx 'BindsTo=open-design.service' '$WORK/example/out/open-design-nginx.container' && grep -qx 'WantedBy=open-design.service' '$WORK/example/out/open-design-nginx.container'"
check "the image tag equals VERSION" bash -c \
  "grep -qx \"Image=localhost/woow-open-design:\$(cat '$REPO/VERSION')\" '$REPO/quadlet/open-design.container'"
check "nginx.conf includes the credential check" grep -qF 'include /etc/nginx/woow-auth.conf;' "$REPO/config/nginx.conf"
check "nginx.conf exempts /api/health" bash -c \
  "grep -A2 'location = /api/health' '$REPO/config/nginx.conf' | grep -q 'auth_basic off'"
check "nginx.conf still injects the export bridge" grep -qF 'sub_filter' "$REPO/config/nginx.conf"
check "the default auth variant asks for a password" grep -qF 'auth_basic_user_file /etc/nginx/htpasswd;' "$REPO/config/nginx-auth.basic.conf"

# Invalid knobs must stop the render before any file is written.
reject() { # reject <description> <KEY> <bad value>
  local env=$WORK/bad-$2.env
  sed "s|^$2=.*|$2=$3|" "$REPO/config/open-design.env.example" >"$env"
  mkdir -p "$WORK/bad-$2/src" "$WORK/bad-$2/out"
  cp -p -- "${base[@]}" "$WORK/bad-$2/src/"
  if (render_variant "$WORK/bad-$2/src" "$env" "$WORK/bad-$2/out") >/dev/null 2>&1; then
    echo "FAIL $1 was accepted"
    failures=$((failures + 1))
  else
    echo "ok   $1 is refused"
  fi
}
reject "a memory limit with shell metacharacters" WOOW_OD_MEMORY '2g;id'
reject "a non-numeric cpu limit" WOOW_OD_CPUS 'two'
reject "an auth mode other than basic/off" WOOW_OD_AUTH 'maybe'
