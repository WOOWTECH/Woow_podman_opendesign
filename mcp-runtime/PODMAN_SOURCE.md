# Source of this directory

An unmodified copy of `image/mcp-runtime/` from `WOOWTECH/Woow_k3s_opendesign` at commit `20fe3ca`, without
its `tests/e2e/`. See `README.md` here for what it contains. Do not edit it by hand.

This stack uses the PaaS placement (`paas_opendesign_mcp`, `bin/paas-opendesign-mcp`) because it fits a
rootless sidecar: no root bootstrap, uid 10001, and the backend and MCP port come from the environment.
`quadlet/open-design-mcp.container` is the equivalent of the chart's `mcp` container.
