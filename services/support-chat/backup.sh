#!/bin/bash
set -euo pipefail
umask 077
profile=/var/lib/xauxat-support-chat
backup_dir=/var/backups/xauxat-support-chat
key=/etc/xauxat-support-chat/backup.key
exec 9>/run/lock/xauxat-support-chat-backup.lock
flock -n 9 || exit 0
test -s "$key"
install -d -m 700 "$backup_dir"
archive="$backup_dir/$(date -u +%Y%m%dT%H%M%SZ).tar.gpg"
restart=0
cleanup() {
    if (( restart )); then systemctl start xauxat-support-chat.service; fi
    if [[ -f "$archive.partial" ]]; then rm -- "$archive.partial"; fi
}
trap cleanup EXIT
if systemctl is-active --quiet xauxat-support-chat.service; then
    restart=1
    systemctl stop xauxat-support-chat.service
fi
# Both databases and files come from the same offline profile. Never start two
# networked copies of these databases: that can break the ratchets/queues.
tar -C "$profile" --exclude=./validation --exclude=./tmp --exclude=./.cache --exclude=./.gnupg -cf - . |
    gpg --batch --yes --no-symkey-cache --pinentry-mode loopback \
        --passphrase-file "$key" --cipher-algo AES256 --symmetric --output "$archive.partial"
mv -- "$archive.partial" "$archive"
if (( restart )); then
    systemctl start xauxat-support-chat.service
    restart=0
fi
# Only encrypted archives inside this fixed backup directory are rotated.
find "$backup_dir" -maxdepth 1 -type f -name '*.tar.gpg' -mmin +10080 -delete
