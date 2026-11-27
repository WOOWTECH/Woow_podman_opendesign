# Source of this directory

Copies of the published `WOOWTECH/opendesign-paseo-plugin` release `v0.3.0` (merge commit
`fa9e28bc785f11f24563b2740c3ae65f42d65210`, Paseo CLI `0.17.5`), identical to the PaaS image source. Do not edit the
runtime tree by hand; replace it from the same immutable archive and lock.

| Here | There |
|---|---|
| `runtime/` | `open-design/paseo-runtime/` of the PaaS build repository (`@woowtech/opendesign-cli-image` 0.3.0, see `runtime/SOURCE.json`) |
| `legal/` | `image/paseo-legal/` (Apache-2.0 text for the `@getpaseo/*` packages built into the image) |
| `paseo-launch.py` | `chart/files/paseo-launch.py` (the supervisor the chart puts in front of the daemon) |

`SOURCE.sha256` lists every copied file; `tests/lint-repo.sh` checks it. To update, copy the same paths from a
newer commit, then regenerate it with `(cd paseo && find legal runtime paseo-launch.py -type f | sort | xargs sha256sum) > paseo/SOURCE.sha256`.
