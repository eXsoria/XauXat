#!/bin/sh

set -eu

: "${NTF_PUBLIC_HOST:?NTF_PUBLIC_HOST is required}"
: "${NTF_DATABASE_URL:?NTF_DATABASE_URL is required}"
: "${APNS_KEY_FILE:?APNS_KEY_FILE is required}"
: "${APNS_KEY_ID:?APNS_KEY_ID is required}"
: "${APNS_TEAM_ID:?APNS_TEAM_ID is required}"
: "${APNS_APP_BUNDLE_ID:?APNS_APP_BUNDLE_ID is required}"

if [ "$APNS_APP_BUNDLE_ID" != "pt.exsoria.xauxat" ]; then
  echo "APNS_APP_BUNDLE_ID must be pt.exsoria.xauxat" >&2
  exit 64
fi

if [ ! -r "$APNS_KEY_FILE" ]; then
  echo "APNs signing key is not readable" >&2
  exit 66
fi

export NTF_SERVER_CFG_PATH=${NTF_SERVER_CFG_PATH:-/etc/opt/simplex-notifications}
export NTF_SERVER_LOG_PATH=${NTF_SERVER_LOG_PATH:-/var/opt/simplex-notifications}

mkdir -p "$NTF_SERVER_CFG_PATH" "$NTF_SERVER_LOG_PATH"

if [ ! -f "$NTF_SERVER_CFG_PATH/ntf-server.ini" ]; then
  ntf-server init \
    --fqdn "$NTF_PUBLIC_HOST" \
    --database "$NTF_DATABASE_URL"
fi

exec ntf-server start
