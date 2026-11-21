# wg-easy-sentinel

A small Bash service that checks a wg-easy container and sends peer activity notifications through [Pushover](https://pushover.net/). It runs entirely on the server and needs no client agents.

Sentinel polls WireGuard handshake timestamps, compares them with persistent state, and queues notifications when a peer becomes active or inactive. WireGuard is silent when idle: **inactive means the last handshake exceeded your threshold, not that the client explicitly disconnected.**

## Quick start

Requires a Linux Docker host, Docker Compose v2, a running wg-easy container, and a Pushover application token and user key.

```sh
git clone https://github.com/valar12/wg-easy-sentinel.git
cd wg-easy-sentinel
cp .env.example .env
```

Edit `.env` with your Pushover credentials and wg-easy container name, then run:

```sh
docker compose up -d --build
docker compose logs -f wg-easy-sentinel
```

Compose builds the source in this checkout and uses the local `wg-easy-sentinel:local` image. It does not pull the original project's image. State and queued notifications live in `/srv/Appdata/wg-easy-sentinel` on the host, mounted at `/app/data`. Set `SENTINEL_DATA_DIR` in `.env` to use another host directory.

```sh
docker compose down
```

The host data directory persists after `down`. Deleting its contents removes notification history and pending deliveries.

## Upgrading an existing installation

The default inactivity threshold changes from **120 to 180 seconds**. Set `TIMEOUT_THRESHOLD=120` explicitly if you need the previous behavior.

The default host data path remains `/srv/Appdata/wg-easy-sentinel`, preserving an existing installation's state automatically. If you used a different directory, set `SENTINEL_DATA_DIR` to that directory before starting. Stop the old service, back up the data directory, retain your environment settings, then rebuild and start the new version.

The previous `connected:...` / `handshake:...` state format is migrated to JSON at the same path, `/app/data/.wg_easy_sentinel_state`. Preserve a backup if you may need to roll back: the old version cannot read the new JSON format. Legacy state is interpreted for the configured `WG_INTERFACE`.

## Configuration

Copy `.env.example` for the common Compose settings. Additional settings can be supplied through the service's `environment` section or `docker run -e`.

| Variable | Default | Purpose |
| --- | --- | --- |
| `WG_CONTAINER_NAME` | `wg-easy` | Container queried with Docker exec. |
| `WG_INTERFACE` | `wg0` | WireGuard interface to monitor. |
| `VPN_NAME` | `wg-vpn` | Label included in notification titles. |
| `POLL_INTERVAL` | `60` | Seconds to wait after each completed monitoring cycle. |
| `TIMEOUT_THRESHOLD` | `180` | Handshake age in seconds that makes a peer inactive. |
| `PUSHOVER_APP_TOKEN` | Required | Pushover application token. |
| `PUSHOVER_USER_KEY` | Required | Pushover user or group key. |
| `PUSHOVER_APP_TOKEN_FILE` | Unset | Read the application token from a mounted secret file. |
| `PUSHOVER_USER_KEY_FILE` | Unset | Read the user key from a mounted secret file. |
| `DRY_RUN` | `false` | Set to `true` to observe without sending or queuing new notifications. |
| `SENTINEL_DATA_DIR` | `/srv/Appdata/wg-easy-sentinel` | Host directory Compose mounts at `/app/data`. |
| `STATE_FILE` | `/app/data/.wg_easy_sentinel_state` | Persistent JSON state and pending notifications. |
| `LOCK_FILE` | `/tmp/wg_monitor.lock` | Prevent overlapping monitor instances. |
| `DOCKER_TIMEOUT` | `10` | Maximum duration of each Docker command, in seconds. |
| `HTTP_CONNECT_TIMEOUT` | `5` | Pushover connection timeout, in seconds. |
| `HTTP_TIMEOUT` | `15` | Overall duration of a Pushover request, in seconds. |
| `NOTIFICATION_BATCH_SIZE` | `5` | Maximum notification attempts in one cycle. |
| `LOG_LEVEL` | `info` | `info` or `debug`. |

Missing credentials are an error unless `DRY_RUN=true`. Use either a direct credential value or its `_FILE` setting. Keep credentials out of Git; `.env` is ignored. For values containing `$`, quote them with single quotes in Compose's `.env` file to avoid interpolation.

State is bound to the configured container and interface. Changing either requires a separate `STATE_FILE` or an intentional migration of the existing state; Sentinel refuses to reuse a file belonging to another scope. Use distinct state and lock files when running multiple monitors. Both paths must be absolute.

For Docker secrets, mount the files and set the corresponding `_FILE` variables. For example, in `compose.override.yaml`:

```yaml
services:
  wg-easy-sentinel:
    environment:
      PUSHOVER_APP_TOKEN_FILE: /run/secrets/pushover_app_token
      PUSHOVER_USER_KEY_FILE: /run/secrets/pushover_user_key
    secrets:
      - pushover_app_token
      - pushover_user_key

secrets:
  pushover_app_token:
    file: ./secrets/pushover_app_token
  pushover_user_key:
    file: ./secrets/pushover_user_key
```

Leave the direct token and user key empty when using secret files. Restrict access to the secret files and state directory.

## How it runs

The container starts a Bash polling loop directly. There is no cron daemon or generated environment script. Each cycle reads the selected interface's latest handshakes, obtains friendly names from wg-easy's configuration where possible, and saves peer state and pending notifications atomically before attempting delivery. Request processing time adds to the configured polling delay. Log timestamps always use UTC in ISO 8601 format.

- Recent handshakes mark a peer active; threshold expiry marks it inactive.
- Repeated snapshots of the same state do not create duplicate events.
- A failed or malformed snapshot preserves the previous observations.
- Failure to read friendly names falls back to the peer public key.
- State persists across restarts. On a fresh installation, currently active peers can generate initial notifications.

Idle peers may become inactive even while their tunnel remains enabled. Pick a threshold suitable for your traffic and keepalive settings. Shorter polling intervals improve detection latency but do not create explicit WireGuard connection events.

## Notification delivery

Pending events survive restarts and failed requests. Transport errors and temporary server failures are retried with backoff during later cycles. Invalid requests or credentials block the affected notification for manual retry; quota failures defer delivery until the reported reset time, or a conservative delay if no reset time is available.

Success requires HTTP 200 and Pushover's JSON `status: 1`. This confirms API acceptance, not that a person read the message. Notification timestamps reflect when Sentinel detected the event, including delayed deliveries.

Delivery is **at least once**: a response lost after Pushover accepts a message, or a crash before recording success, can result in a duplicate. Dry run updates observations but leaves existing pending notifications untouched and creates no new ones; transitions observed only in dry run are not replayed later.

To retry blocked notifications after correcting the underlying problem, stop the watcher and run:

```sh
docker compose stop wg-easy-sentinel
docker compose run --rm wg-easy-sentinel /app/wg-easy-sentinel.sh --retry-failed
docker compose up -d wg-easy-sentinel
```

## Commands and health

```sh
/app/wg-easy-sentinel.sh --watch         # Poll continuously.
/app/wg-easy-sentinel.sh --once          # Perform one cycle.
/app/wg-easy-sentinel.sh --healthcheck   # Check the last successful observation.
/app/wg-easy-sentinel.sh --retry-failed  # Requeue blocked notifications and exit.
/app/wg-easy-sentinel.sh --help
```

The container healthcheck detects stale or missing successful observations. A healthy monitor does not guarantee notification delivery; inspect logs for queued, blocked, or failed requests. Storage errors and unavailable Docker access must be fixed before normal monitoring can resume.

`--once` exits nonzero if its snapshot fails, an attempted notification fails, or blocked notifications remain. Notifications waiting for their retry time do not by themselves make the check fail. `--watch` logs unsuccessful checks and continues with the next cycle.

## Security

Sentinel needs Docker socket access to execute read commands in wg-easy. **Docker socket access grants broad control over the host.** A read-only socket mount does not make the Docker API read-only. Run only an image and source you trust, and limit access to the host, credentials, and data volume.

The container uses a read-only root filesystem with writable temporary storage and a dedicated state volume. State contains peer public keys, names, and notification text; treat it as private operational data. Do not share unredacted state or configuration when reporting issues.

## Development

Requires Bash 4.4 or later, `jq`, `curl`, Docker CLI, `flock`, and GNU `timeout`. Tests use fake Docker and Pushover commands and do not contact either service:

```sh
bash tests/run.sh
shellcheck wg-easy-sentinel.sh entrypoint.sh build-and-push.sh tests/run.sh
docker compose build
```

CI checks shell syntax, ShellCheck, regression tests, and the container build. Linux CI is authoritative for the supported runtime. Git Bash can run the mocked tests on Windows, but the locking test is skipped when `flock` is unavailable. Shell scripts use LF line endings so Windows checkouts do not change their executable format.

### GitHub Container Registry image

After CI succeeds, pushes to `main` or `modernize-existing` publish `ghcr.io/valar12/wg-easy-sentinel:latest` and `:sha-<full-commit>` for `linux/amd64` and `linux/arm64`. A manual CI workflow dispatch also publishes after tests pass. Pull requests do not publish. GitHub Actions uses its built-in `GITHUB_TOKEN`; no personal access token is required for this workflow.

The default Compose configuration builds locally. To use the published image, create `compose.ghcr.yaml`:

```yaml
services:
  wg-easy-sentinel:
    image: ghcr.io/valar12/wg-easy-sentinel:latest
    pull_policy: always
```

Then run:

```sh
docker compose -f docker-compose.yml -f compose.ghcr.yaml pull
docker compose -f docker-compose.yml -f compose.ghcr.yaml up -d --no-build
```

This preserves the existing data bind mount and environment configuration. Replace `latest` with a `sha-<full-commit>` tag to select a specific build. Private packages require `docker login ghcr.io` with an account that has package read access.

### Manual versioned release

Commit the source and start with a clean checkout. Set `GITHUB_USER_OR_ORG`, `GITHUB_USER`, and `GITHUB_PAT` in your shell, then run `bash build-and-push.sh v1.2.3` with the intended release version. `NEW_TAG` is also supported. The helper checks and builds an archive of the exact commit before asking for confirmation to publish the versioned and `latest` GHCR images and push the Git tag. It does not read credentials from `.env`.

See [CHANGELOG.md](CHANGELOG.md) for upgrade notes. This project is distributed under the [MIT license](LICENSE).
