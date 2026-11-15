# N100 deployment reliability

The first Podman keep-id ownership mapping now has a 900-second systemd startup budget. Before replacing the namespace owner, only its three named namespace joiners are removed. Existing BindsTo/After dependencies stop those services first; data volumes are retained.

The same runtime settings were exercised on an existing N100 with 53 containers. All containers recovered automatically after a physical reboot; the completed read-only check was at boot uptime 558.4 seconds. This is an observation, not a fixed startup-time guarantee.

[Physical-host evidence](https://github.com/WOOWTECH/Woow_ubuntu_version_control/blob/195dcda9357100a7821407e1c8469a349acc9831/distribution/docs/reboot-acceptance.md).
