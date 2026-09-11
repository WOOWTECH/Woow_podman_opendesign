# shellcheck shell=bash
# scripts/render-args.sh: values computed from ~/.config/open-design/open-design.env. Sourced by
# scripts/install.sh and tests/dryrun.sh, so CI renders exactly what a host gets.
#
# render_args <envfile>: QL_ENV is already loaded from <envfile>; sets RENDER_ARGS=(KEY=VALUE...) and
# validates the values that are rendered straight from the env file.
render_args() {
  local bind port prefix
  bind=$(ql_env_get WOOW_OD_BIND)
  ql_assert_match WOOW_OD_BIND "$bind" 'all|[0-9]{1,3}(\.[0-9]{1,3}){3}'
  port=$(ql_env_get WOOW_OD_PORT)
  ql_assert_match WOOW_OD_PORT "$port" '[1-9][0-9]{0,4}'
  ((port <= 65535)) || ql_die "WOOW_OD_PORT: $port is not a TCP port"
  ql_assert_match WOOW_OD_MEMORY "$(ql_env_get WOOW_OD_MEMORY)" '[0-9]+[bkmgBKMG]?'
  ql_assert_match WOOW_OD_CPUS "$(ql_env_get WOOW_OD_CPUS)" '[0-9]+(\.[0-9]+)?'
  ql_assert_match WOOW_OD_AUTH "$(ql_env_get WOOW_OD_AUTH basic)" 'basic|off'
  # "all" publishes on every address family (IPv4 and IPv6): omit the host IP.
  if [[ $bind == all ]]; then prefix=''; else prefix="$bind:"; fi
  # shellcheck disable=SC2034 # RENDER_ARGS is read by the caller
  RENDER_ARGS=("OD_PUBLISH=$prefix$port")
}
