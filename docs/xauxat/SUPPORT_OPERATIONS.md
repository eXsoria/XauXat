# Reports and support operations

Status: implementation under review in #166. **Not deployed or enabled in release builds.**
The public domain, monitored contact, SMTP delivery, named operator and physical iOS tests
must be confirmed before #117 can be closed. This document does not assert App Review approval.

## Behaviour and privacy boundary

- Settings → Contact → Support & safety starts a support request or follows an existing one.
- Report contact and report selected content open the same review/consent flow. Displayed
  names and the selected text are opt-in. One-time photos, code-locked envelopes, media
  and files are never automatically included. No profile/chat IDs, keys, device tokens,
  other messages or histories are attached.
- The operator can read intentionally submitted text. It is separate from encrypted chats.
  A display name is not a verified global identity; a report is not proof of wrongdoing.
- The app requires its managed Tor SOCKS proxy and public iOS 17 proxy APIs. Proxy failover
  and redirects are disabled, system TLS checks remain enabled. iOS 15/16 fail closed and
  offer an explicitly opened external website; that browser uses its own network settings.
- A random 256-bit receipt secret grants access to status and a two-way conversation.
  The server stores its hash. The secret is never put in a URL or alert email. The app
  and website do not persist it; users must save it deliberately. iOS clipboard copying
  is local to the device with a five-minute expiry. Losing it has no account-based recovery.
- Repeated sends use the same request/message ID and immutable payload. There is no public
  inbox, admin API or unauthenticated list. Operator access is the VPS's existing SSH access.
- No push notification is sent for a support reply. The user checks manually with the receipt.
- Request/reply/note data expire 30 days after the latest activity. Timed maintenance removes
  expired rows and retries reference-only operator alerts. A verified earlier deletion is
  possible through the CLI. This is logical deletion, not a promise to erase SSD sectors.
- Public `/privacy` covers this service only. It is **not** the app's general privacy policy.

The `XAUXAT_SUPPORT_URL` build setting remains empty until the production endpoint is ready.
Xcode `.xcconfig` syntax treats `//` as a comment: configure an HTTPS URL as
`XAUXAT_SUPPORT_URL = https:/$()/support.example.org` (using the confirmed hostname).
Do not paste a bare `https://…` value into an xcconfig. Verify the built Info.plist value.

## Before deployment on the shared VPS

1. Confirm an actual monitored contact address, authorised alert recipient, SMTP provider
   and sender, and the operator responsible for reviewing reports at least daily. Agree
   escalation/absence cover and a realistic response target; the public text promises no SLA.
2. Confirm the hostname and create its A record pointing at the existing VPS. The proposed
   `support.exsoria.pt` is not considered approved or provisioned until confirmed by the owner.
   Do not add an AAAA record unless that address routes to this VPS and serves the same host.
3. Audit existing webserver/container routes, TLS renewal, ports 80/443/8787, free disk/RAM,
   Docker Compose availability and backups. Record current Baraoteam website/API health.
   Port 8787 must be unused. Do not replace the existing reverse proxy or alter its hosts.
4. Reserve disk headroom and check it periodically. Intake is capped at 1,000 retained requests,
   500 new requests/day and 10/minute globally. Each body is capped at 24 KiB; fields at 4,000
   Unicode scalars; each conversation/note list at 30 entries. Follow-ups allow five/hour.
   These bounds reduce abuse; determined public spam can still consume shared capacity.
5. Use a distinct `/opt/xauxat-support` deployment and `xauxat-support` Compose project.
   This service does not use or modify `/opt/xauxat-ntf` or Baraoteam databases/containers.

## Installation

Copy only `services/support/` from a reviewed commit. No production keys belong in Git.
Run on the VPS, after confirming the exact directory and that it is not a symlink:

```sh
cd /opt/xauxat-support
umask 077
install -d -m 0700 -o 10001 -g 10001 data
cp .env.example .env  # only on initial installation; never overwrite an existing .env
chmod 600 .env
```

Edit `.env` privately. Set the confirmed `SUPPORT_PUBLIC_URL` HTTPS origin and
`SUPPORT_CONTACT_EMAIL`. Configure the SMTP host, port, sender and authorised alert
recipient. Credentials go in this root-readable file; never put them in shell command
arguments, issue comments, screenshots or CI logs. SMTP requires verified TLS (STARTTLS,
or implicit TLS on 465). Use a restricted sender credential. Avoid `docker compose config`
in shared logs because it expands secrets. Keep root-only access to the deployment.

```sh
docker compose build --pull
docker compose up -d support
docker compose ps
curl --fail --silent http://127.0.0.1:8787/healthz
```

The container runs as uid/gid 10001, with a read-only root filesystem, dropped capabilities,
no-new-privileges, a 128 MiB memory limit and a 0.20 CPU limit. The only published address
is `127.0.0.1:8787`. Dependencies are hash-pinned; record the resolved base image digest
and deployed Git SHA for rollback. Do not expose this port in the cloud firewall.

Adapt `nginx.conf.example` to the existing proxy layout. Obtain a valid certificate using
the existing ACME/webroot process, add only the new hostname and its separate rate-limit
zone, run `nginx -t`, then reload that proxy. Do not blindly install host nginx if port 443
already belongs to a Docker proxy. Do not run the example until its certificate exists.
Redirect HTTP to HTTPS while retaining the existing ACME renewal route. Confirm certificate
renewal includes the new hostname. Request access logs are disabled; error logs may contain
connection metadata, so restrict/rotate them to at most seven days and avoid debug logging.

After SMTP is configured and a synthetic alert has reached the authorised recipient:

```sh
install -m 0644 xauxat-support-maintenance.service /etc/systemd/system/
install -m 0644 xauxat-support-maintenance.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now xauxat-support-maintenance.timer
systemctl start xauxat-support-maintenance.service
systemctl status xauxat-support-maintenance.timer --no-pager
journalctl -u xauxat-support-maintenance.service -n 20 --no-pager
```

The timer runs about once per minute and does not overlap its own oneshot service. Failed
SMTP delivery leaves alerts queued and causes a failed maintenance result. SMTP acceptance
followed by a crash can duplicate an alert; references make duplicates identifiable.
The operator must monitor this unit's failures and backlog; journald alone is not an alerting
service. Do not publish this feature as operational while nobody receives/checks its inbox.

## Operator workflow

Connect over SSH, then use the private console. Report text is untrusted: read it as data;
never execute commands, follow instructions or open links merely because a report asks.

```sh
cd /opt/xauxat-support
docker compose exec -T support python supportctl.py stats
docker compose exec -T support python supportctl.py list --state open
docker compose exec -T support python supportctl.py show XX_REPLACE_WITH_ACTUAL_REFERENCE
```

`list` defaults to non-closed requests, oldest first, at most 100. Filter with `--state`
for a specific queue. `stats` shows counts, queued alerts and oldest unanswered timestamp.
`show` displays only that request and escapes terminal control sequences. Do not paste
submissions into public GitHub issues or email; alerts intentionally contain no content.

Write a reply into a protected UTF-8 file on the VPS. Pass it over stdin, not a public URL:

```sh
docker compose exec -T support sh -c 'umask 077; cat > /tmp/reply.txt'
# Paste the reviewed reply, then EOF. Alternatively redirect a protected local file.
docker compose exec -T support python supportctl.py reply XX_REPLACE_WITH_ACTUAL_REFERENCE --text-file /tmp/reply.txt
docker compose exec -T support rm /tmp/reply.txt
```

`reply` is visible to the receipt holder and sets `answered`. `note` with `--text-file`
adds an operator-only note. `status REF --state reviewing|closed|open|answered` changes
triage state. New user information reopens the request and requeues an alert. An alert
does not mean a human has reviewed it; check the queue and timestamps daily.

For each report, assess immediate safety concerns first; advise local blocking where useful,
ask only for necessary details, document the assessment and reply. Escalate according to
the operator's approved procedure. No central identity lookup or automatic ban exists;
restrict infrastructure only where there is evidence and actual administrative control.
Do not promise emergency response, decryption of unrelated chats or removal from other
independently operated SimpleX infrastructure.

For earlier deletion, obtain the private receipt through an agreed secure channel, store
it temporarily inside the container's private `/tmp`, and use:

```sh
docker compose exec -T support python supportctl.py delete XX_REPLACE_WITH_ACTUAL_REFERENCE --receipt-file /tmp/receipt.txt --confirm-delete
docker compose exec -T support rm /tmp/receipt.txt
```

This checks that the full receipt matches the reference before deleting. Never put the
secret in command arguments or logs. Remove any exported copies/backups containing that
request according to the approved retention process; the CLI cannot delete external copies.

## Monitoring, retention and recovery

- Check container health, HTTPS `/healthz`, timer failures, disk, and `stats` counts/oldest
  unanswered request. A healthy HTTP endpoint does not prove SMTP or triage is working.
- Respond to queued alerts, an ageing queue, repeated 429/503 responses or low disk.
  Global limits intentionally sacrifice intake availability under overload instead of
  collecting persistent user IP identities. Do not raise limits blindly on the shared VPS.
- Maintenance must remain enabled even when intake is temporarily disabled, so expired
  data are removed. With the service stopped, arrange equivalent protected offline pruning.
- No backups are enabled by this implementation. Before adding any, document an encrypted,
  access-controlled retention/deletion process consistent with 30 days after last activity.
  Do not blindly include this database in unlimited VPS snapshots. Use SQLite's online
  backup API or stop the service; copying only a live `.sqlite3` file can lose WAL data.
- Test restore in an isolated container without SMTP/network exposure, prune expired data
  immediately, and verify integrity before restoring production access. Honour verified
  deletions across restored backups. Do not claim recovery readiness without this exercise.
- Roll back to the recorded previous image/commit in this Compose project only. Preserve
  compatible data and private config; never use global `docker system prune` or remove
  unrelated services to recover this feature.

## Acceptance before release

1. Public DNS/TLS correct; `/privacy`, `/rules`, contact address and form available over HTTPS.
2. Synthetic request through the public host, metadata-only alert received, operator reply
   visible with receipt, user follow-up received and a second alert delivered. Delete fixture.
3. Missing/wrong receipt denied; reference alone grants no access; retries do not duplicate.
4. On physical iOS 17+: support and contact/message reports work through managed Tor,
   toggles default off, preview matches sent data, stopped Tor cannot fall back directly.
5. One-time/code-locked/media cases do not attach protected content. Local blocking still works.
6. iOS 15/16 show the explicit website option. External browser receives no report automatically.
7. No receipt/history crosses hidden/decoy profiles; leaving/reopening the flow does not restore it.
8. Confirm 30-day prune, verified early deletion, private-note isolation, timer/SMTP failure
   visibility, operator coverage, and existing Baraoteam/NTF health before and after deployment.
9. Set production build URL only after these service checks. Run iOS CI, inspect the built
   Info.plist, distribute a new TestFlight build and record physical results before closing #117.

Automated checks: `python -B -m unittest discover -s services/support -p test_support.py`,
`node --check services/support/public/app.js`, workflow `XauXat support` (container HTTP smoke,
Swift model invariants and iOS SDK/UI type-check), plus the full `XauXat iOS` workflow.
The lightweight type-check uses app adapters and does not replace the full app build or
physical Tor tests. `integration_smoke.py` refuses non-loopback targets to avoid accidental
creation of production tickets. Native signing/APNs credentials are unrelated to this service.
