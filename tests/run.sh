#!/usr/bin/env bash
# Integration tests use subprocess fixtures; no Docker daemon or Pushover account is used.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for dependency in bash jq timeout; do
  command -v "$dependency" >/dev/null || { printf 'Missing test dependency: %s\n' "$dependency" >&2; exit 1; }
done

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sentinel-tests.XXXXXXXX")
cleanup() {
  # Only remove the temporary directory created by this process.
  case "$TEST_ROOT" in */sentinel-tests.????????) rm -rf -- "$TEST_ROOT" ;; esac
}
trap cleanup EXIT
mkdir -p "$TEST_ROOT/bin"
REAL_DATE=$(command -v date)
export REAL_DATE
cat > "$TEST_ROOT/bin/date" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n ${MOCK_NOW:-} && ${*: -1} == +%s ]]; then
  printf '%s\n' "$MOCK_NOW"
else
  exec "$REAL_DATE" "$@"
fi
MOCK

cat > "$TEST_ROOT/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DIR/docker.calls"
case "$*" in
  *latest-handshakes*)
    [[ ${MOCK_DOCKER_FAIL:-} != handshakes ]] || exit 1
    cat "$MOCK_DIR/handshakes"
    ;;
  *'cat '*'.conf'*)
    [[ ${MOCK_DOCKER_FAIL:-} != config ]] || exit 1
    cat "$MOCK_DIR/config"
    ;;
  *inspect*)
    [[ ${MOCK_DOCKER_FAIL:-} != inspect ]] || exit 1
    printf 'running\n'
    ;;
  info*) [[ ${MOCK_DOCKER_FAIL:-} != info ]] ;;
  *) printf 'Unexpected Docker command: %s\n' "$*" >&2; exit 2 ;;
esac
MOCK

cat > "$TEST_ROOT/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >> "$MOCK_DIR/curl.calls"
body_file= headers_file= write_format=
while (($#)); do
  case "$1" in
    --output|-o) body_file=$2; shift 2 ;;
    --dump-header|-D) headers_file=$2; shift 2 ;;
    --write-out|-w) write_format=$2; shift 2 ;;
    *) shift ;;
  esac
done
status=${MOCK_HTTP_STATUS:-200}
body=${MOCK_HTTP_BODY:-'{"status":1,"request":"mock-request"}'}
if [[ -n "$headers_file" ]]; then
  printf 'HTTP/1.1 %s Mock\r\nX-Limit-App-Reset: %s\r\n\r\n' "$status" "${MOCK_QUOTA_RESET:-0}" > "$headers_file"
fi
if [[ -n "$body_file" ]]; then printf '%s' "$body" > "$body_file"; else printf '%s' "$body"; fi
if [[ -n "$write_format" ]]; then printf '%b' "${write_format//\%\{http_code\}/$status}"; fi
exit "${MOCK_CURL_EXIT:-0}"
MOCK
chmod +x "$TEST_ROOT/bin/date" "$TEST_ROOT/bin/docker" "$TEST_ROOT/bin/curl"

HAS_FLOCK=true
if ! command -v flock >/dev/null; then
  HAS_FLOCK=false
  # Git Bash lacks flock. Linux CI exercises actual kernel-backed locking.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_ROOT/bin/flock"
  chmod +x "$TEST_ROOT/bin/flock"
fi

export PATH="$TEST_ROOT/bin:$PATH"
export PUSHOVER_APP_TOKEN=test-app-token PUSHOVER_USER_KEY=test-user-key
export WG_CONTAINER_NAME=test-wireguard WG_INTERFACE=wg0 VPN_NAME=test-vpn
export POLL_INTERVAL=1 TIMEOUT_THRESHOLD=180 DOCKER_TIMEOUT=2
export HTTP_CONNECT_TIMEOUT=1 HTTP_TIMEOUT=2 NOTIFICATION_BATCH_SIZE=5
export DRY_RUN=false
PEER=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

fail() { printf '  %s\n' "$*" >&2; return 1; }
assert_json() { jq -e "$1" "$STATE_FILE" >/dev/null || fail "State assertion failed: $1"; }
assert_calls() {
  local count=0
  if [[ -f "$MOCK_DIR/curl.calls" ]]; then count=$(wc -l < "$MOCK_DIR/curl.calls"); fi
  [[ $count -eq $1 ]] || fail "Expected $1 HTTP calls, found $count"
}
active_peer() { printf '%s\t%s\n' "$PEER" "$(date +%s)" > "$MOCK_DIR/handshakes"; }
run_monitor() { bash "$ROOT/wg-easy-sentinel.sh" "$@" > "$MOCK_DIR/stdout" 2> "$MOCK_DIR/stderr"; }
check_ok() {
  if ! run_monitor "$@"; then cat "$MOCK_DIR/stderr" >&2; fail "Monitor unexpectedly failed: $*"; return 1; fi
}
check_fails() {
  if run_monitor "$@"; then fail "Monitor unexpectedly succeeded: $*"; return 1; fi
}
make_due() {
  jq '.pending |= map(.next_attempt = 0)' "$STATE_FILE" > "$MOCK_DIR/due.json"
  mv "$MOCK_DIR/due.json" "$STATE_FILE"
}

test_first_connection() {
  active_peer
  check_ok --once
  assert_json '.peers["'"$PEER"'"].active == true and (.pending | length) == 0'
  check_ok --once
  assert_calls 1
  grep -q 'wg show wg0 latest-handshakes' "$MOCK_DIR/docker.calls"
  [[ ! -s "$MOCK_DIR/stdout" ]] || fail 'Diagnostic output leaked to stdout'
}
test_empty_snapshot() {
  active_peer; check_ok --once
  : > "$MOCK_DIR/handshakes"
  check_ok --once
  assert_calls 2
  assert_json '([.peers[] | select(.active)] | length) == 0'
}
test_failed_snapshot() {
  active_peer; check_ok --once
  cp "$STATE_FILE" "$MOCK_DIR/before"
  export MOCK_DOCKER_FAIL=handshakes
  check_fails --once
  cmp "$STATE_FILE" "$MOCK_DIR/before"
  assert_calls 1
}
test_delivery_during_observer_failure() {
  active_peer
  export MOCK_HTTP_STATUS=503 MOCK_HTTP_BODY='{"status":0}'
  check_fails --once
  make_due
  export MOCK_DOCKER_FAIL=handshakes MOCK_HTTP_STATUS=200 MOCK_HTTP_BODY='{"status":1}'
  check_fails --once
  assert_calls 2
  assert_json '.peers["'"$PEER"'"].active and (.pending | length) == 0'
}
test_malformed_snapshot() {
  active_peer; check_ok --once
  cp "$STATE_FILE" "$MOCK_DIR/before"
  printf 'unexpected diagnostics, not a snapshot\n' > "$MOCK_DIR/handshakes"
  check_fails --once
  cmp "$STATE_FILE" "$MOCK_DIR/before"
  assert_calls 1
}
test_retry_survives_restart() {
  active_peer
  export MOCK_HTTP_STATUS=503 MOCK_HTTP_BODY='{"status":0}'
  check_fails --once
  assert_json '.peers["'"$PEER"'"].active and (.pending | length) == 1 and .pending[0].attempts > 0'
  make_due
  export MOCK_HTTP_STATUS=200 MOCK_HTTP_BODY='{"status":1,"request":"recovered"}'
  check_ok --once
  assert_json '(.pending | length) == 0'
  assert_calls 2
}
test_bad_success_body() {
  active_peer
  export MOCK_HTTP_BODY='{"status":0}'
  check_fails --once
  assert_json '(.pending | length) == 1'
}
test_non_json_response() {
  active_peer
  export MOCK_HTTP_BODY='temporarily unavailable'
  check_fails --once
  assert_json '(.pending | length) == 1'
}
test_network_failure() {
  active_peer
  export MOCK_CURL_EXIT=28 MOCK_HTTP_STATUS=000 MOCK_HTTP_BODY=''
  check_fails --once
  assert_json '(.pending | length) == 1 and .pending[0].attempts > 0'
}
test_authentication_failure() {
  active_peer
  export MOCK_HTTP_STATUS=400 MOCK_HTTP_BODY='{"status":0,"errors":["invalid token"]}'
  check_fails --once
  assert_json '(.pending | length) == 1 and .pending[0].blocked == true'
  check_fails --once
  assert_calls 1
  check_ok --retry-failed
  assert_json '.pending[0].blocked == false'
  export MOCK_HTTP_STATUS=200 MOCK_HTTP_BODY='{"status":1}'
  check_ok --once
  assert_calls 2
  assert_json '(.pending | length) == 0'
}
test_quota_backoff() {
  active_peer
  export MOCK_HTTP_STATUS=429 MOCK_HTTP_BODY='{"status":0}'
  export MOCK_QUOTA_RESET=$(( $(date +%s) + 7200 ))
  check_fails --once
  assert_json '.pending[0].next_attempt >= '"$MOCK_QUOTA_RESET"
  check_ok --once
  assert_calls 1
}
test_per_peer_ordering() {
  active_peer
  export MOCK_HTTP_STATUS=503 MOCK_HTTP_BODY='{"status":0}'
  check_fails --once
  : > "$MOCK_DIR/handshakes"
  check_ok --once
  assert_json '(.pending | length) == 2 and .pending[0].kind == "active" and .pending[1].kind == "inactive"'
  assert_calls 1
  make_due
  export MOCK_HTTP_STATUS=200 MOCK_HTTP_BODY='{"status":1}'
  check_ok --once
  assert_json '(.pending | length) == 0'
  assert_calls 3
}
test_unique_transition_ids() {
  export MOCK_NOW
  MOCK_NOW=$("$REAL_DATE" +%s)
  active_peer
  export MOCK_HTTP_STATUS=503 MOCK_HTTP_BODY='{"status":0}'
  check_fails --once
  : > "$MOCK_DIR/handshakes"
  check_ok --once
  active_peer
  check_ok --once
  assert_json '(.pending | length) == 3 and ([.pending[].id] | unique | length) == 3'
  make_due
  export MOCK_HTTP_STATUS=200 MOCK_HTTP_BODY='{"status":1}'
  check_ok --once
  assert_json '(.pending | length) == 0'
  assert_calls 4
}
test_legacy_migration() {
  active_peer
  printf 'connected:%s:1\nhandshake:%s:%s\n' "$PEER" "$PEER" "$(date +%s)" > "$STATE_FILE"
  check_ok --once
  assert_json '.version == 1 and .peers["'"$PEER"'"].active == true'
  assert_calls 0
}
test_missing_names() {
  active_peer
  export MOCK_DOCKER_FAIL=config
  check_ok --once
  assert_calls 1
}
test_small_clock_skew() {
  printf '%s\t%s\n' "$PEER" "$(( $(date +%s) + 1 ))" > "$MOCK_DIR/handshakes"
  check_ok --once
  assert_json '.peers["'"$PEER"'"].active == true'
}
test_invalid_future_timestamp() {
  active_peer; check_ok --once
  cp "$STATE_FILE" "$MOCK_DIR/before"
  printf '%s\t%s\n' "$PEER" "$(( $(date +%s) + 86400 ))" > "$MOCK_DIR/handshakes"
  check_fails --once
  cmp "$STATE_FILE" "$MOCK_DIR/before"
}
test_secret_files() {
  active_peer
  unset PUSHOVER_APP_TOKEN PUSHOVER_USER_KEY
  export PUSHOVER_APP_TOKEN_FILE="$MOCK_DIR/app-secret" PUSHOVER_USER_KEY_FILE="$MOCK_DIR/user-secret"
  # Keep the substitution literal to detect unsafe shell evaluation of secrets.
  # shellcheck disable=SC2016
  printf 'before$(printf INJECTED)after' > "$PUSHOVER_APP_TOKEN_FILE"
  printf 'user"with\\literal' > "$PUSHOVER_USER_KEY_FILE"
  check_ok --once
  jq -e '.[0] | index("token=before$(printf INJECTED)after") != null' -s "$MOCK_DIR/curl.calls" >/dev/null
  jq -e '.[0] | index("user=user\"with\\literal") != null' -s "$MOCK_DIR/curl.calls" >/dev/null
  ! grep -q 'before\|user"with' "$MOCK_DIR/stderr"
}
test_missing_credentials() {
  active_peer
  unset PUSHOVER_APP_TOKEN PUSHOVER_USER_KEY
  check_fails --once
  assert_calls 0
  [[ ! -f "$STATE_FILE" ]] || fail 'Missing credentials should not consume observed transitions'
}
test_dry_run() {
  active_peer
  export DRY_RUN=true
  unset PUSHOVER_APP_TOKEN PUSHOVER_USER_KEY
  check_ok --once
  assert_json '.peers["'"$PEER"'"].active and (.pending | length) == 0'
  assert_calls 0
}
test_dry_run_preserves_pending() {
  active_peer
  export MOCK_HTTP_STATUS=503 MOCK_HTTP_BODY='{"status":0}'
  check_fails --once
  jq '.pending' "$STATE_FILE" > "$MOCK_DIR/pending.before"
  export DRY_RUN=true
  : > "$MOCK_DIR/handshakes"
  check_ok --once
  jq '.pending' "$STATE_FILE" > "$MOCK_DIR/pending.after"
  cmp "$MOCK_DIR/pending.before" "$MOCK_DIR/pending.after"
  assert_calls 1
}
test_http_timeouts() {
  active_peer; check_ok --once
  jq -e '.[0] | index("--connect-timeout") != null and index("--max-time") != null' -s "$MOCK_DIR/curl.calls" >/dev/null
}
test_storage_failure() {
  active_peer
  mkdir "$MOCK_DIR/not-a-directory"
  printf 'file\n' > "$MOCK_DIR/not-a-directory/file"
  export STATE_FILE="$MOCK_DIR/not-a-directory/file/state"
  check_fails --once
  assert_calls 0
}
test_corrupt_state() {
  active_peer
  printf '{"version":1,"peers":' > "$STATE_FILE"
  cp "$STATE_FILE" "$MOCK_DIR/before"
  check_fails --once
  cmp "$STATE_FILE" "$MOCK_DIR/before"
  assert_calls 0
}
test_invalid_pending_counters() {
  active_peer
  export MOCK_HTTP_STATUS=503 MOCK_HTTP_BODY='{"status":0}'
  check_fails --once
  cp "$STATE_FILE" "$MOCK_DIR/valid-state"
  for invalid_attempts in -1 0.5; do
    jq --argjson attempts "$invalid_attempts" '.pending[0].attempts = $attempts' "$MOCK_DIR/valid-state" > "$STATE_FILE"
    cp "$STATE_FILE" "$MOCK_DIR/before"
    check_fails --once
    cmp "$STATE_FILE" "$MOCK_DIR/before"
    assert_calls 1
  done
}
test_multiple_state_documents() {
  active_peer; check_ok --once
  cat "$STATE_FILE" "$STATE_FILE" > "$MOCK_DIR/duplicate-documents"
  mv "$MOCK_DIR/duplicate-documents" "$STATE_FILE"
  cp "$STATE_FILE" "$MOCK_DIR/before"
  check_fails --once
  cmp "$STATE_FILE" "$MOCK_DIR/before"
  assert_calls 1
}
test_invalid_settings() {
  active_peer
  export POLL_INTERVAL=not-a-number
  check_fails --once
  assert_calls 0
}
test_healthcheck() {
  check_fails --healthcheck
  active_peer; check_ok --once
  check_ok --healthcheck
  jq '.last_success = 1' "$STATE_FILE" > "$MOCK_DIR/stale.json"
  mv "$MOCK_DIR/stale.json" "$STATE_FILE"
  check_fails --healthcheck
}
test_lock_contention() {
  if [[ $HAS_FLOCK != true ]]; then printf '  SKIP kernel locking unavailable on this host\n'; return 77; fi
  active_peer
  (
    flock -x 9
    printf 'ready\n' > "$MOCK_DIR/lock.ready"
    sleep 5
  ) 9> "$LOCK_FILE" &
  local holder=$!
  for ((attempt=0; attempt<50; attempt++)); do [[ ! -f "$MOCK_DIR/lock.ready" ]] || break; sleep 0.02; done
  check_fails --once
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  assert_calls 0
}
test_watch_shutdown() {
  active_peer
  POLL_INTERVAL=60 bash "$ROOT/wg-easy-sentinel.sh" --watch > "$MOCK_DIR/stdout" 2> "$MOCK_DIR/stderr" &
  local watcher=$! ready=false stopped=false
  for ((attempt=0; attempt<100; attempt++)); do
    if [[ -s "$STATE_FILE" ]]; then ready=true; break; fi
    if ! kill -0 "$watcher" 2>/dev/null; then break; fi
    sleep 0.1
  done
  if [[ $ready != true ]]; then
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    cat "$MOCK_DIR/stderr" >&2
    fail 'Watch mode did not perform its first check promptly'
    return 1
  fi
  kill -TERM "$watcher"
  for ((attempt=0; attempt<50; attempt++)); do
    if ! kill -0 "$watcher" 2>/dev/null; then stopped=true; break; fi
    sleep 0.1
  done
  if [[ $stopped != true ]]; then kill -KILL "$watcher" 2>/dev/null || true; fi
  wait "$watcher" 2>/dev/null || true
  [[ $stopped == true ]] || fail 'SIGTERM did not interrupt the 60-second polling wait'
}
test_watch_secret_files() {
  unset PUSHOVER_APP_TOKEN PUSHOVER_USER_KEY
  export PUSHOVER_APP_TOKEN_FILE="$MOCK_DIR/app-secret" PUSHOVER_USER_KEY_FILE="$MOCK_DIR/user-secret"
  printf 'test-app-token\n' > "$PUSHOVER_APP_TOKEN_FILE"
  printf 'test-user-key\n' > "$PUSHOVER_USER_KEY_FILE"
  test_watch_shutdown
}

tests=(first_connection empty_snapshot failed_snapshot delivery_during_observer_failure malformed_snapshot retry_survives_restart
  bad_success_body non_json_response network_failure authentication_failure quota_backoff per_peer_ordering unique_transition_ids
  legacy_migration missing_names small_clock_skew invalid_future_timestamp secret_files missing_credentials
  dry_run dry_run_preserves_pending http_timeouts storage_failure corrupt_state invalid_pending_counters multiple_state_documents
  invalid_settings healthcheck lock_contention watch_shutdown watch_secret_files)
if (($#)); then tests=("$@"); fi
export ROOT TEST_ROOT HAS_FLOCK PEER
export -f fail assert_json assert_calls active_peer run_monitor check_ok check_fails make_due test_watch_shutdown
for name in "${tests[@]}"; do export -f "test_$name"; done
passed=0 skipped=0 failed=0
for name in "${tests[@]}"; do
  printf 'TEST %s\n' "$name"
  mkdir "$TEST_ROOT/$name"
  # Run each case in its own Bash process so errexit stays active inside test functions.
  if bash -euo pipefail -c '
    unset PUSHOVER_APP_TOKEN_FILE PUSHOVER_USER_KEY_FILE MOCK_DOCKER_FAIL MOCK_HTTP_STATUS MOCK_HTTP_BODY MOCK_QUOTA_RESET MOCK_CURL_EXIT MOCK_NOW
    export MOCK_DIR="$TEST_ROOT/$2" STATE_FILE="$TEST_ROOT/$2/state" LOCK_FILE="$TEST_ROOT/$2/lock"
    : > "$MOCK_DIR/handshakes"
    printf "# Client: Test Peer (test-id)\n[Peer]\nPublicKey = %s\n" "$PEER" > "$MOCK_DIR/config"
    "test_$2"
  ' _ unused "$name"; then
    passed=$((passed + 1))
  else
    test_status=$?
    if [[ $test_status -eq 77 ]]; then
      skipped=$((skipped + 1))
    else
      failed=$((failed + 1))
      printf 'FAIL %s\n' "$name" >&2
    fi
  fi
done
printf '\n%s passed; %s skipped; %s failed\n' "$passed" "$skipped" "$failed"
[[ $failed -eq 0 ]]
