#!/usr/bin/env bash
set -euo pipefail
umask 077

CONTAINER_NAME=${WG_CONTAINER_NAME:-wg-easy}
WG_INTERFACE=${WG_INTERFACE:-wg0}
VPN_NAME=${VPN_NAME:-wg-vpn}
TIMEOUT_THRESHOLD=${TIMEOUT_THRESHOLD:-180}
POLL_INTERVAL=${POLL_INTERVAL:-60}
STATE_FILE=${STATE_FILE:-/app/data/.wg_easy_sentinel_state}
LOCK_FILE=${LOCK_FILE:-/tmp/wg_monitor.lock}
DOCKER_TIMEOUT=${DOCKER_TIMEOUT:-10}
HTTP_CONNECT_TIMEOUT=${HTTP_CONNECT_TIMEOUT:-5}
HTTP_TIMEOUT=${HTTP_TIMEOUT:-15}
NOTIFICATION_BATCH_SIZE=${NOTIFICATION_BATCH_SIZE:-5}
DRY_RUN=${DRY_RUN:-false}
LOG_LEVEL=${LOG_LEVEL:-info}
PUSHOVER_API_URL=https://api.pushover.net/1/messages.json
SCRIPT_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")
TEMP_DIR=
STATE=

log() { printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" >&2; }
debug() { if [[ $LOG_LEVEL == debug ]]; then log debug "$*"; fi; }
die() { log error "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: wg-easy-sentinel.sh [--watch|--once|--healthcheck|--retry-failed|--help]

  --watch         Check immediately, then wait POLL_INTERVAL seconds (default).
  --once          Take one snapshot and attempt pending notifications.
  --healthcheck   Check freshness of the last successful snapshot; no API calls.
  --retry-failed  Requeue blocked notifications after fixing credentials/config.

Required: PUSHOVER_APP_TOKEN and PUSHOVER_USER_KEY, or their *_FILE variants.
Set DRY_RUN=true to observe without creating or delivering notifications.
See README.md and .env.example for configuration and migration instructions.
EOF
}

validate_config() {
  local name value
  for name in TIMEOUT_THRESHOLD POLL_INTERVAL DOCKER_TIMEOUT HTTP_CONNECT_TIMEOUT HTTP_TIMEOUT NOTIFICATION_BATCH_SIZE; do
    value=${!name}
    [[ $value =~ ^[1-9][0-9]{0,5}$ ]] || die "$name must be a positive integer (at most six digits)."
  done
  [[ $DRY_RUN == true || $DRY_RUN == false ]] || die 'DRY_RUN must be true or false.'
  [[ $LOG_LEVEL == info || $LOG_LEVEL == debug ]] || die 'LOG_LEVEL must be info or debug.'
  [[ $WG_INTERFACE =~ ^[a-zA-Z0-9_=+.-]{1,15}$ ]] || die 'WG_INTERFACE is not a valid interface name.'
  [[ $CONTAINER_NAME =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die 'WG_CONTAINER_NAME is not a valid container name or ID.'
  [[ $STATE_FILE == /* && $LOCK_FILE == /* ]] || die 'STATE_FILE and LOCK_FILE must be absolute paths.'
}

read_secret() {
  local name=$1 file_name="${1}_FILE" value=${!1:-} file
  file=${!file_name:-}
  [[ -z $value || -z $file ]] || die "Set either $name or $file_name, not both."
  if [[ -n $file ]]; then
    [[ -r $file ]] || die "Cannot read $file_name."
    value=$(< "$file")
  fi
  [[ -n $value ]] || die "$name or $file_name is required (or set DRY_RUN=true)."
  printf -v "$name" '%s' "$value"
}

save_state() {
  local temporary
  temporary=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || return 1
  if ! printf '%s\n' "$STATE" > "$temporary" || ! mv -f -- "$temporary" "$STATE_FILE"; then
    rm -f -- "$temporary"
    log error 'Cannot persist state; check data volume permissions and free space.'
    return 1
  fi
}

load_state() {
  local type key value extra migrated=false
  STATE='{"version":1,"peers":{},"pending":[],"last_success":0}'
  if [[ -f $STATE_FILE ]]; then
    if jq -e . "$STATE_FILE" >/dev/null 2>&1; then
      STATE=$(jq -cse '
        def uint: if type == "number" then . >= 0 and . == floor and . <= 9007199254740991 else false end;
        if length == 1 then .[0] else error("expected one state document") end |
        if .version == 1 and (.peers | type == "object") and (.pending | type == "array")
          and (.last_success | uint)
          and (.next_event_id == null or (.next_event_id | uint))
          and all(.peers[]; (.active | type == "boolean") and (.last_handshake | uint) and (.name | type == "string"))
          and all(.pending[]; (.id | type == "string") and (.peer | type == "string")
            and (.title | type == "string") and (.message | type == "string")
            and (.timestamp | uint) and (.attempts | uint and . <= 1000000)
            and (.next_attempt | uint) and (.blocked | type == "boolean"))
          and (([.pending[].id] | unique | length) == (.pending | length))
        then . else error("unsupported or invalid state") end
      ' "$STATE_FILE") || die 'State file is invalid; preserve it and restore a valid backup.'
    else
      # Read the original colon-delimited state as data, never as shell code.
      while IFS=: read -r type key value extra || [[ -n $type ]]; do
        [[ -n $type ]] || continue
        [[ -z $extra && $key =~ ^[A-Za-z0-9+/=_-]+$ ]] || die 'Malformed legacy state file.'
        case $type in
          connected)
            [[ $value == 1 ]] || die 'Malformed legacy connection state.'
            STATE=$(jq -c --arg key "$key" '.peers[$key] = ((.peers[$key] // {active:false,last_handshake:0,name:$key}) + {active:true})' <<< "$STATE")
            ;;
          handshake)
            [[ $value =~ ^[0-9]{1,12}$ ]] || die 'Malformed legacy handshake timestamp.'
            STATE=$(jq -c --arg key "$key" --argjson timestamp "$((10#$value))" '.peers[$key] = ((.peers[$key] // {active:false,last_handshake:0,name:$key}) + {last_handshake:$timestamp})' <<< "$STATE")
            ;;
          *) die 'Unrecognized state file format; refusing to overwrite it.' ;;
        esac
      done < "$STATE_FILE"
      migrated=true
    fi
  fi
  if ! jq -e --arg container "$CONTAINER_NAME" --arg interface "$WG_INTERFACE" '
    .scope == null or .scope == {container:$container,interface:$interface}
  ' <<< "$STATE" >/dev/null; then
    die 'State belongs to another container/interface; use a separate STATE_FILE.'
  fi
  STATE=$(jq -c --arg container "$CONTAINER_NAME" --arg interface "$WG_INTERFACE" '.scope = {container:$container,interface:$interface}' <<< "$STATE")
  if [[ $migrated == true ]]; then log info 'Loaded legacy state; the next successful snapshot will migrate it to JSON.'; fi
}

fetch_peers() {
  local output config line key timestamp extra friendly='' peers='{}' names='{}' now=$1
  if ! output=$(timeout --kill-after=2s "$DOCKER_TIMEOUT" docker exec "$CONTAINER_NAME" wg show "$WG_INTERFACE" latest-handshakes); then
    log error 'WireGuard snapshot failed; previous peer state is unchanged.'
    return 1
  fi
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    read -r key timestamp extra <<< "$line"
    if [[ -n $extra || ! $key =~ ^[A-Za-z0-9+/=_-]+$ || ! $timestamp =~ ^[0-9]{1,12}$ ]]; then
      log error 'Malformed WireGuard snapshot; previous peer state is unchanged.'
      return 1
    fi
    timestamp=$((10#$timestamp))
    if (( timestamp > now + 300 )); then
      log error 'WireGuard timestamp is too far in the future; check the host clock.'
      return 1
    fi
    peers=$(jq -c --arg key "$key" --argjson timestamp "$timestamp" '
      if has($key) then error("duplicate peer") else .[$key] = {last_handshake:$timestamp} end
    ' <<< "$peers") || return 1
  done <<< "$output"

  # Names are optional metadata: a missing config must not stop monitoring.
  if config=$(timeout --kill-after=2s "$DOCKER_TIMEOUT" docker exec "$CONTAINER_NAME" cat "/etc/wireguard/${WG_INTERFACE}.conf" 2>/dev/null); then
    while IFS= read -r line; do
      line=${line%$'\r'}
      if [[ $line =~ ^#\ Client:\ (.*)\ \(.+\)$ ]]; then
        friendly=${BASH_REMATCH[1]}
      elif [[ $line =~ ^PublicKey[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
        key=${BASH_REMATCH[1]}
        if [[ -n $friendly ]]; then
          names=$(jq -c --arg key "$key" --arg name "$friendly" '.[$key]=$name' <<< "$names") || return 1
        fi
        friendly=''
      elif [[ $line == '[Interface]' ]]; then
        friendly=''
      fi
    done <<< "$config"
  else
    log warn 'Friendly names unavailable; using stored names or public keys.'
  fi
  jq -c --argjson names "$names" 'with_entries(.value.name = ($names[.key] // ""))' <<< "$peers"
}

observe() {
  local now=$1 peers=$2
  STATE=$(jq -c --argjson peers "$peers" --argjson now "$now" --argjson threshold "$TIMEOUT_THRESHOLD" \
    --arg vpn "$VPN_NAME" --argjson dry_run "$DRY_RUN" '
    .peers as $previous |
    ($peers | with_entries(
      .key as $key |
      .value.name = (if .value.name == "" then ($previous[$key].name // $key) else .value.name end) |
      .value.active = (.value.last_handshake > 0 and (($now - .value.last_handshake) < $threshold))
    )) as $current |
    ([($current | keys[]), ($previous | keys[])] | unique) as $keys |
    (if $dry_run then [] else [
      $keys[] as $key |
      ($previous[$key].active // false) as $was |
      ($current[$key].active // false) as $active |
      select($was != $active) |
      (if $active then "active" else "inactive" end) as $kind |
      ($current[$key].name // $previous[$key].name // $key) as $name |
      ($current[$key].last_handshake // $previous[$key].last_handshake // 0) as $last |
      {peer:$key,kind:$kind,timestamp:$now,
       title:(("[" + $vpn + "] Peer " + $kind)[0:250]),
       message:(("Peer " + $name + " is " + $kind + ". Last handshake " + ([0,($now-$last)]|max|tostring) + " seconds ago. Inactivity is inferred.")[0:1024]),
       attempts:0,next_attempt:$now,blocked:false}
    ] end) as $events |
    reduce $events[] as $event (.;
      .next_event_id = ((.next_event_id // 0) + 1) |
      .pending += [$event + {id:(.next_event_id | tostring)}]
    ) |
    .peers = $current | .last_success = $now
  ' <<< "$STATE") || return 1
  # Persist observations and pending events together before contacting Pushover.
  save_state
}

deliver_pending() {
  local now=$1 event id peer title message timestamp attempts status code delay next blocked count
  local processed=0 failed=0 waiting='[]'
  [[ $DRY_RUN == false ]] || return 0
  while IFS= read -r event; do
    peer=$(jq -r '.peer' <<< "$event")
    # Preserve event order for each peer, including a blocked earlier event.
    if jq -e --arg peer "$peer" 'index($peer) != null' <<< "$waiting" >/dev/null; then continue; fi
    waiting=$(jq -c --arg peer "$peer" '. + [$peer]' <<< "$waiting") || return 1
    if ! jq -e --argjson now "$now" '.blocked == false and .next_attempt <= $now' <<< "$event" >/dev/null; then continue; fi
    if (( processed >= NOTIFICATION_BATCH_SIZE )); then break; fi
    processed=$((processed + 1))
    id=$(jq -r '.id' <<< "$event")
    title=$(jq -r '.title' <<< "$event")
    message=$(jq -r '.message' <<< "$event")
    timestamp=$(jq -r '.timestamp' <<< "$event")
    code=0
    status=$(curl --silent --show-error --proto '=https' \
      --connect-timeout "$HTTP_CONNECT_TIMEOUT" --max-time "$HTTP_TIMEOUT" \
      --output "$TEMP_DIR/response" --dump-header "$TEMP_DIR/headers" --write-out '%{http_code}' \
      --data-urlencode "token=$PUSHOVER_APP_TOKEN" --data-urlencode "user=$PUSHOVER_USER_KEY" \
      --data-urlencode "title=$title" --data-urlencode "message=$message" --data-urlencode "timestamp=$timestamp" \
      "$PUSHOVER_API_URL") || code=$?
    if (( code == 0 )) && [[ $status == 200 ]] && jq -e '.status == 1' "$TEMP_DIR/response" >/dev/null 2>&1; then
      STATE=$(jq -c --arg id "$id" '.pending |= map(select(.id != $id))' <<< "$STATE") || return 1
      save_state || return 1
      waiting=$(jq -c --arg peer "$peer" 'map(select(. != $peer))' <<< "$waiting") || return 1
      log info "Pushover accepted: $title"
      continue
    fi
    failed=1
    attempts=$(jq -r '.attempts + 1' <<< "$event")
    # Bounded exponential backoff, without blocking the next observation.
    delay=3600
    if (( attempts < 8 )); then delay=$((30 * (1 << (attempts - 1)))); fi
    next=$((now + delay))
    blocked=false
    if (( code == 0 )); then
      case $status in
        429)
          next=$(awk 'tolower($1)=="x-limit-app-reset:" {gsub("\r", "", $2); print $2}' "$TEMP_DIR/headers" | tail -n 1)
          if [[ ! $next =~ ^[0-9]{1,12}$ ]] || (( 10#$next <= now )); then next=$((now + 3600)); else next=$((10#$next)); fi
          ;;
        4??) blocked=true ;;
      esac
      if [[ $status == 200 ]] && jq -e '.status == 0' "$TEMP_DIR/response" >/dev/null 2>&1; then blocked=true; fi
    fi
    STATE=$(jq -c --arg id "$id" --argjson attempts "$attempts" --argjson next "$next" --argjson blocked "$blocked" '
      .pending |= map(if .id == $id then . + {attempts:$attempts,next_attempt:$next,blocked:$blocked} else . end)
    ' <<< "$STATE") || return 1
    save_state || return 1
    # Response bodies can echo identifiers; log only safe status information.
    log warn "Notification retained: HTTP ${status:-000}, curl exit $code, blocked=$blocked."
  done < <(jq -c '.pending[]' <<< "$STATE")
  count=$(jq '[.pending[] | select(.blocked)] | length' <<< "$STATE")
  if (( count > 0 )); then log warn "$count notification(s) blocked; fix configuration, then use --retry-failed."; failed=1; fi
  (( failed == 0 ))
}

healthcheck() {
  local last now max_age
  command -v jq >/dev/null || return 1
  [[ -r $STATE_FILE ]] || return 1
  last=$(jq -er '.last_success | select(type == "number" and . > 0)' "$STATE_FILE") || return 1
  now=$(date +%s)
  max_age=$((POLL_INTERVAL * 3 + DOCKER_TIMEOUT * 2 + HTTP_TIMEOUT * NOTIFICATION_BATCH_SIZE))
  (( now >= last && now - last <= max_age ))
}

check_dependencies() {
  local dependency
  for dependency in jq docker timeout curl flock; do command -v "$dependency" >/dev/null || die "Required command not found: $dependency"; done
}

run_once() {
  local now peers observed=0 delivery=0
  check_dependencies
  if [[ $DRY_RUN == false ]]; then read_secret PUSHOVER_APP_TOKEN; read_secret PUSHOVER_USER_KEY; fi
  mkdir -p -- "$(dirname -- "$STATE_FILE")" "$(dirname -- "$LOCK_FILE")" || die 'Cannot create state/lock directory.'
  exec 200> "$LOCK_FILE"
  flock -n 200 || die 'Another Sentinel check is running.'
  TEMP_DIR=$(mktemp -d)
  trap 'rm -rf -- "$TEMP_DIR"' EXIT
  load_state
  now=$(date +%s)
  if peers=$(fetch_peers "$now"); then
    observe "$now" "$peers" || die 'Cannot save observation.'
    debug "Snapshot saved for $CONTAINER_NAME/$WG_INTERFACE."
  else
    observed=1
  fi
  deliver_pending "$now" || delivery=1
  (( observed == 0 && delivery == 0 ))
}

retry_failed() {
  command -v jq >/dev/null || die 'Required command not found: jq'
  command -v flock >/dev/null || die 'Required command not found: flock'
  [[ -f $STATE_FILE ]] || die 'No state file to update.'
  mkdir -p -- "$(dirname -- "$LOCK_FILE")" || die 'Cannot create lock directory.'
  exec 200> "$LOCK_FILE"
  flock -n 200 || die 'Stop the running watcher before requeuing notifications.'
  load_state
  STATE=$(jq -c '.pending |= map(if .blocked then . + {blocked:false,attempts:0,next_attempt:0} else . end)' <<< "$STATE")
  save_state || die 'Cannot requeue notifications.'
  log info 'Blocked notifications requeued; start the watcher to deliver them.'
}

watch() {
  local child=''
  trap 'if [[ -n $child ]]; then kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi; exit 0' TERM INT
  log info "Watching $CONTAINER_NAME/$WG_INTERFACE every ${POLL_INTERVAL}s (handshake timeout ${TIMEOUT_THRESHOLD}s)."
  while true; do
    bash "$SCRIPT_PATH" --once &
    child=$!
    if ! wait "$child"; then log warn 'Check incomplete; pending notifications and previous observations are retained.'; fi
    sleep "$POLL_INTERVAL" &
    child=$!
    wait "$child"
  done
}

main() {
  local mode=${1:---watch}
  [[ $# -le 1 ]] || { usage >&2; return 2; }
  case $mode in --help|-h) usage; return 0 ;; --watch|--once|--healthcheck|--retry-failed) ;; *) usage >&2; return 2 ;; esac
  validate_config
  case $mode in
    --healthcheck) healthcheck ;;
    --once) run_once ;;
    --retry-failed) retry_failed ;;
    --watch)
      check_dependencies
      # Validate without exporting resolved file secrets to child checks.
      if [[ $DRY_RUN == false ]]; then (read_secret PUSHOVER_APP_TOKEN; read_secret PUSHOVER_USER_KEY); fi
      watch
      ;;
  esac
}

main "$@"
