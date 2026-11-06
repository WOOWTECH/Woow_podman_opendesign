# Source of this directory

Unmodified copies from `WOOWTECH/Woow_k3s_opendesign` at commit `20fe3ca19da0434eac02399ec50a9db612b77a77`
(the PaaS image and chart), so this stack runs the same Paseo as the PaaS service. Do not edit them by hand.

| Here | There |
|---|---|
| `runtime/` | `image/paseo-runtime/` (`@woowtech/opendesign-cli-image` 0.2.3, see `runtime/SOURCE.json`) |
| `legal/` | `image/paseo-legal/` (Apache-2.0 text for the `@getpaseo/*` packages built into the image) |
| `paseo-launch.py` | `chart/files/paseo-launch.py` (the supervisor the chart puts in front of the daemon) |

`SOURCE.sha256` lists every copied file; `tests/lint-repo.sh` checks it. To update, copy the same paths from a
newer commit, then regenerate it with `(cd paseo && find legal runtime paseo-launch.py -type f | sort | xargs sha256sum) > paseo/SOURCE.sha256`.
