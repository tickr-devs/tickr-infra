# Web stack (AWS): tickr.bot

One small server for the public site, the web app (`web/`) and its Postgres, apart from the bot
(owner decision 2026-11-25: a break-in through the website must not reach the broker keys).
It shares no role, secret or network with the bot. DNS stays at Namecheap.

What it creates (about **17.50 USD a month**):
- `tickr-web`: t4g.small (2 Graviton vCPU, 2 GB), Ubuntu 24.04, 20 GB encrypted gp3, an Elastic
  IP. Only ports 80 and 443 are open; no SSH, the owner reaches it through SSM. About 12.30 USD
  for the machine, 1.60 for the disk and 3.65 for the public IPv4 address.
- `tickr-web-<account id>`: private, encrypted, versioned S3 bucket, TLS only: `backups/`
  (nightly `pg_dump`) and `releases/` (what `ship.sh` uploads). Each object is deleted after
  `keep_days` (30); an overwritten or expired one is kept `overwritten_keep_days` (7) more, so
  a dump is gone for good within 37 days. The machine can write but not delete, so a
  broken-into machine cannot destroy the dumps, and an overwrite can be undone for 7 days.
  Cents a month.
- SES identity for `tickr.bot` with DKIM, so mail comes from `hello@tickr.bot`. 0.10 USD per
  1,000 emails.
- Role `tickr-web` for the machine: SSM, write `backups/`, read `releases/`, send mail from
  the domain. Nothing else.

The app's secret key and the database password are generated on the machine at first boot and
never leave it; they are not in Terraform state, the repository or the bucket.

The database lives on the machine's disk, so the instance has termination protection: a
`terraform destroy` or a terminate in the console is refused (see "Removing the server").

HTTPS is strict for a year on `tickr.bot` **and every subdomain** (HSTS with
`includeSubDomains` in `web/deploy/Caddyfile`): any `*.tickr.bot` host must serve HTTPS.

- Alarms mailed to `alert_email` (topic `tickr-web-alarms`; confirm AWS's link once):
  `tickr-web-system-check` (AWS hardware failed; the machine is also recovered onto new
  hardware), `tickr-web-instance-check` (the system does not answer), `tickr-web-site-down`
  (a Route 53 health check cannot fetch `https://tickr.bot/` for `site_down_minutes`) and
  `tickr-web-backup-missing` (no dump uploaded for `backup_missing_hours`; `backup.sh` sends one
  point after each upload). About 1.20 USD a month: 0.50 for the health check, 0.40 for four
  alarms, 0.30 for the backup metric. The backup alarm stays on until the first night after the
  apply.

## First setup (owner, on the Mac)

1. Create the stack (needs `brew install terraform awscli` and the admin profile):
   ```sh
   cd ~/Development/tickr-infra/ops/aws/web
   terraform init
   terraform apply -var alert_email='you@example.com'
   terraform output dns_records_for_namecheap
   ```
2. Namecheap > Domain List > tickr.bot > Advanced DNS: delete the old A/CNAME records for `@`
   and `www` (the free hosting), then add every record from the output (A `@`, A `www`, TXT
   `_dmarc`, three CNAME `…._domainkey`).
3. SES starts in its sandbox (mail only to verified addresses). In the AWS console, SES >
   Account dashboard > Request production access: mail type Transactional, website
   https://tickr.bot, use "sign-in codes and early-access list confirmations, double opt-in,
   every email has an unsubscribe link". Usually approved within a day.
4. First release, with the built public site:
   ```sh
   cd ~/Development/tickr-web && web/deploy/ship.sh /path/to/site-v2/out
   ```
   Caddy gets the HTTPS certificate by itself once the DNS records have spread (minutes to an
   hour).
5. Owner account, then sign in at https://tickr.bot/login with the emailed code and add a passkey
   (the admin at /app/admin/ needs a passkey sign-in):
   ```sh
   aws ssm start-session --target "$(terraform output -raw instance_id)"
   sudo -u tickrweb sh -c 'cd /srv/tickr-web/repo/web/deploy && set -a && . /srv/tickr-web/etc/compose.env && set +a && docker compose exec app /entrypoint.sh /venv/bin/python manage.py invite you@example.com --superuser'
   ```
6. Old early-access list: download `tickr-signups/emails.csv` from Namecheap File Manager,
   copy it into the app container, and run `manage.py import_waitlist emails.csv` the same
   way. Each address gets a confirmation email.

## Turn on the alarms (server already running)

The alarms came after the first setup. Apply once, then ship, so the machine may send the backup
point before `backup.sh` starts sending it:
```sh
cd ~/Development/tickr-web && git switch main && git pull
cd ops/aws/web && terraform plan -var alert_email='you@example.com'   # adds only the alarms, topic, health check and one role statement
terraform apply -var alert_email='you@example.com'
cd ~/Development/tickr-web && web/deploy/ship.sh
```
Confirm the link AWS mails. The plan must not replace `aws_instance.web`.

## Later releases

tickr-web's `web/deploy/ship.sh` (app only) or `web/deploy/ship.sh SITE_DIR` (app and site), from a
clean `web/` at a commit that is on `origin/main` (reviewed and merged; ship.sh refuses any
other). Migrations run when the app starts. Each release removes the previous image.

A release lives in `releases/` for `keep_days` only. The server keeps what it installed, so
that matters only for a new machine: run `ship.sh SITE_DIR` once after creating one.

## Restore a backup

```sh
aws s3 ls s3://tickr-web-<account id>/backups/tickrweb/
```
The machine may write backups but not read them. To restore one, copy it to `releases/` with
the admin profile, fetch it on the machine with `aws s3 cp`, and run
`pg_restore --clean --if-exists -U tickrweb -d tickrweb` inside the `db` container. Then
delete it from `releases/` with the admin profile: every container on the server can read
that folder through the instance role.

## Removing the server

Take a backup first. Then set `disable_api_termination = false` in `main.tf`, `terraform
apply`, and only then `terraform destroy`.
