#!/bin/sh
set -eu
umask 077
export HOME=/var/lib/xauxat-support-chat
exec /opt/xauxat-support-chat/bin/simplex-chat \
  --database /var/lib/xauxat-support-chat/support \
  --user-display-name XauXatSupport \
  --device-name XauXatSupportVPS \
  --files-folder /var/lib/xauxat-support-chat/files \
  --temp-folder /var/lib/xauxat-support-chat/tmp \
  --log-level error --mute --disable-backup --yes-migrate
