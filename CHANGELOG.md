# Changelog

## Unreleased

### Changed

- Keep the existing server-only Bash/Docker polling model and Pushover integration.
- Replace cron and generated environment files with a direct polling loop.
- Increase the default handshake inactivity threshold from 120 to 180 seconds; explicit overrides remain supported.
- Monitor a configurable WireGuard interface and describe notifications as inferred activity/inactivity.
- Bind state to the configured container and interface to prevent accidental reuse across monitors.
- Store observed state and pending notifications together in an atomically replaced JSON file. Migrate the legacy state format in place.
- Build the checked-out source by default instead of pulling the upstream image. Use a current Alpine base and a read-only container filesystem.

### Fixed

- Retain failed notifications across monitoring cycles and container restarts.
- Bound Docker and HTTP calls; validate both HTTP and Pushover response status.
- Handle empty and malformed snapshots without parsing log messages as peer data.
- Preserve observations when Docker is unavailable; use public keys if friendly names cannot be read.
- Handle future timestamps safely and report persistence failures.
- Remove environment serialization, environment dumps, and plaintext environment files generated for cron.

### Added

- Configurable polling interval, explicit dry run, mounted-secret support, and monitor healthcheck.
- Commands for one-shot checks and retrying blocked notifications.
- Mocked regression tests, ShellCheck, and container build checks in CI.

### Upgrade notes

- The default host data path remains `/srv/Appdata/wg-easy-sentinel`. Set `SENTINEL_DATA_DIR` if your existing installation uses another directory.
- Back up the legacy state file before upgrading; older releases cannot read the JSON format.
- Missing Pushover credentials now fail configuration validation unless `DRY_RUN=true`.
- Use `TIMEOUT_THRESHOLD=120` to preserve the previous threshold. Inactivity remains an inference from handshake age.
