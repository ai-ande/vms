# vms

Deploy modules for the Mac mini's headless infrastructure (cloned under
`~akaplan/git/vms`). Each subdirectory is an independently-installable module
managed by the `mini-server` orchestrator + dashboard.

- **homeassistant-vm**, **adguard-vm** — headless VMware Fusion VMs, run as
  `vmhost` via system LaunchDaemons. `start-vm.sh` is idempotent (no-op if
  already running, clears stale `.lck`) and writes a run-record.
- **ha-backup-mirror** — mirrors Home Assistant `*.tar` backups from the SMB
  landing zone (`/Users/Shared/ha-backups`) to **Proton Drive** via the official
  Proton Drive CLI. Runs as a **gui LaunchAgent for akaplan** (needs akaplan's
  GUI session for the login Keychain). Success requires the backup to be verified
  present in Proton Drive — not merely copied.

Each `install.sh` supports `--check` (report only) and `uninstall`, and is run as
root (by the ajk helper, the mini-server `install.sh`, or `sudo ./install.sh`).
Run-records land in `/usr/local/var/log/ajk/vms/<job>/` and feed the dashboard.

Shared deps (created by `mini-server`'s `install.sh`): the `ajklog` group, the
`/usr/local/var/log/ajk` tree, and `/usr/local/libexec/ajk/run-record.sh`.
