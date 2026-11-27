# Source of this directory

Candidate copies prepared from `WOOWTECH/opendesign-paseo-plugin` commit
`b7a44452720c39e34c61f65d80ffbf3961f276c3` (`0.3.0-rc.1`, Paseo CLI
`0.17.5`) and aligned with the candidate PaaS image source. Do not edit the
runtime tree by hand; replace it from the same immutable archive and lock.

| Here | There |
|---|---|
| `runtime/` | candidate `image/paseo-runtime/` (`@woowtech/opendesign-cli-image` 0.3.0-rc.1, see `runtime/SOURCE.json`) |
| `legal/` | `image/paseo-legal/` (Apache-2.0 text for the `@getpaseo/*` packages built into the image) |
| `paseo-launch.py` | `chart/files/paseo-launch.py` (the supervisor the chart puts in front of the daemon) |

`SOURCE.sha256` lists every copied file; `tests/lint-repo.sh` checks it. To update, copy the same paths from a
newer commit, then regenerate it with `(cd paseo && find legal runtime paseo-launch.py -type f | sort | xargs sha256sum) > paseo/SOURCE.sha256`.
