# sidekick
scientific sidekick

## Simulator Logs

Use `scripts/sidekick-sim-logs.sh` to persist Sidekick simulator logs across agent sessions.

Examples:

```sh
./scripts/sidekick-sim-logs.sh start
./scripts/sidekick-sim-logs.sh status
./scripts/sidekick-sim-logs.sh tail --lines 200 --follow
./scripts/sidekick-sim-logs.sh stream
```

The script writes local runtime state under `.sidekick-runtime/`:
- `latest-simulator.log` symlink to the current capture file in `~/Library/Logs/Sidekick/`
- `sim-log-stream.env` with the active device/process metadata
- the persistent capture itself lives in `~/Library/Logs/Sidekick/`

`start` installs or refreshes a user LaunchAgent so the capture survives future agent sessions. `stream` is the foreground live view for the current shell.

## GitHub Bootstrap Service

Sidekick's secure one-repo Codex setup flow needs a small GitHub bootstrap backend. Deployment notes live in [docs/bootstrap-service.md](docs/bootstrap-service.md).
