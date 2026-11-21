#!/usr/bin/env bash
set -euo pipefail

if [[ $# == 0 ]]; then
  set -- /app/wg-easy-sentinel.sh --watch
elif [[ $1 == -* ]]; then
  set -- /app/wg-easy-sentinel.sh "$@"
fi

# Inherit the runtime environment directly; never serialize or print secrets.
exec "$@"
