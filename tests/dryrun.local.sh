# shellcheck shell=bash
# tests/dryrun.local.sh: OpenDesign-specific assertions. Sourced at the end of tests/dryrun.sh
# (vendored), which provides run_variant, render_variant, $WORK, $REPO, $base, $failures.
# shellcheck disable=SC2154 # the variables above are defined by tests/dryrun.sh

check() { # check <description> <command...>
  if "${@:2}"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}
has_line() { grep -qxF -- "$3" "$WORK/$1/out/$2"; }

check "example publishes nginx's port on 127.0.0.1" has_line example open-design.container 'PublishPort=127.0.0.1:7456:7456'
check "example uses the default limits" has_line example open-design.container 'PodmanArgs=--memory=4g --cpus=2'
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

# Paseo: install.sh's od_check_paseo, run on the example settings plus the given ones.
paseo_case() { # paseo_case <description> <ok|refused> <auth> [KEY=VALUE...]
  local pc_desc=$1 pc_want=$2 pc_auth=$3 pc_env=$WORK/paseo.env pc_out=$WORK/paseo.conf pc_kv pc_got
  shift 3
  cp "$REPO/config/open-design.env.example" "$pc_env"
  for pc_kv in "$@"; do sed -i "s|^${pc_kv%%=*}=.*|$pc_kv|" "$pc_env"; done
  rm -f "$pc_out"
  if (
    # shellcheck source=scripts/common.sh
    . "$REPO/scripts/common.sh"
    # shellcheck source=scripts/od-helpers.sh
    . "$REPO/scripts/od-helpers.sh"
    ql_env_load "$pc_env"
    od_check_paseo "$(ql_env_get WOOW_OD_PASEO off)" "$pc_auth" "$pc_out"
  ) >/dev/null 2>&1; then pc_got=ok; else pc_got=refused; fi
  if [[ $pc_got == "$pc_want" ]]; then echo "ok   Paseo: $pc_desc"; else echo "FAIL Paseo: $pc_desc ($pc_got)"; failures=$((failures + 1)); fi
}
po=OD_ALLOWED_ORIGINS=http://127.0.0.1:7456,https://od.example.com
paseo_case "off by default renders the off answer" ok basic
check "Paseo: the off include proxies nothing" bash -c "! grep -q proxy_pass '$WORK/paseo.conf'"
paseo_case "on with an allowed https origin" ok basic WOOW_OD_PASEO=on OPENDESIGN_PASEO_ORIGIN=https://od.example.com "$po"
check "Paseo: the origin is a literal in the nginx regex" grep -qF 'https://od\.example\.com$' "$WORK/paseo.conf"
paseo_case "on without an origin" refused basic WOOW_OD_PASEO=on "$po"
paseo_case "on with an http origin" refused basic WOOW_OD_PASEO=on OPENDESIGN_PASEO_ORIGIN=http://od.example.com OD_ALLOWED_ORIGINS=http://127.0.0.1:7456,http://od.example.com
paseo_case "on with an origin not in OD_ALLOWED_ORIGINS" refused basic WOOW_OD_PASEO=on OPENDESIGN_PASEO_ORIGIN=https://other.example.com "$po"
paseo_case "on with a path in the origin" refused basic WOOW_OD_PASEO=on OPENDESIGN_PASEO_ORIGIN=https://od.example.com/x "$po"
paseo_case "on with WOOW_OD_AUTH=off" refused off WOOW_OD_PASEO=on OPENDESIGN_PASEO_ORIGIN=https://od.example.com "$po"
paseo_case "a value other than on/off" refused basic WOOW_OD_PASEO=yes
