#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

address=$(docker compose exec -T ntf sh -c 'printf "ntf://%s@%s" "$(cat "$NTF_SERVER_CFG_PATH/fingerprint")" "$NTF_PUBLIC_HOST"')
encoded=$(printf '%s' "$address" | base64 | tr -d '\n')

printf 'Notification server: %s\n' "$address"
printf 'XAUXAT_NTF_SERVER_B64 = %s\n' "$encoded"
