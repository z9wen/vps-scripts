# vps-scripts

Scripts I use on my own VPS hosts and machines, kept in one place. This is
personal tooling: read a script before running it, and use it at your own risk.

| Path | What it is |
| --- | --- |
| [`xray/`](xray/) | Modular Xray installer and manager, a personal fork of [mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent). The sources build into the single file `xray/xray-install.sh`. |
| `bbr/bbr_optimizer.sh` | Linux network tuning profiles (BBR and related sysctl settings) with a timed automatic revert. |
| `backup/rclone-backup.sh` | Mirrors local site and database backups to an `rclone` remote. It uses `rclone sync`, so files deleted locally are also deleted on the remote. |
| `tools/codex_ghost_cleaner.py` | Repairs stale local Codex/ChatGPT chat indexes on macOS. |

## Checks

```bash
pip install -r requirements-dev.txt   # pytest and ruff
make check                            # syntax, ShellCheck and tests
make xray-build                       # rebuild xray/xray-install.sh locally
```

CI runs the same checks on every push and rebuilds `xray/xray-install.sh`
whenever the Xray sources change.

## Licence

Released under the [AGPL-3.0 licence](LICENSE). The code under `xray/` is
derived from mack-a/v2ray-agent, which is also AGPL-3.0; see
[`xray/README.md`](xray/README.md) for what was changed.
