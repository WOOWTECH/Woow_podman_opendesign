# Source of this directory

Copies of the published `WOOWTECH/opendesign-paseo-plugin` release `v0.3.1` (merge commit
`6e0add40859ce0019aff0c3a9d18af4e57088b01`, Paseo CLI `0.17.5`), identical to the PaaS image source. Do not edit the
runtime tree by hand; replace it from the same immutable archive and lock.

| Here | There |
|---|---|
| `runtime/` | `open-design/paseo-runtime/` of the PaaS build repository (`@woowtech/opendesign-cli-image` 0.3.1, see `runtime/SOURCE.json`) |
| `legal/` | `image/paseo-legal/` (Apache-2.0 text for the `@getpaseo/*` packages built into the image) |
| `paseo-launch.py` | `chart/files/paseo-launch.py` (the supervisor the chart puts in front of the daemon) |

`SOURCE.sha256` lists every copied file; `tests/lint-repo.sh` checks it. To update, copy the same paths from a
newer commit, then regenerate it with `(cd paseo && find legal runtime paseo-launch.py -type f | sort | xargs sha256sum) > paseo/SOURCE.sha256`.
