# Bot server (AWS)

The owner's bot on one AWS server instead of the Mac (`docs/backlog.md` T15, plan
https://claude.ai/artifact/QhzoePqMNyeqFeYwUga59C). This directory is the first part: the machine,
its disks, address, secret, role, nightly snapshots and machine alarms. Later parts add the
runtime on it (secrets into memory, Caddy, the rendered systemd units, the heartbeat) and the
release image.

**Applying this stack starts a paid server.** Apply only after the owner's yes on a named sum.
The account budget in `ops/aws/training` (`monthly_budget_usd`) must be raised by the server's
monthly cost at the same time.

## What it creates

| Resource | Why |
|---|---|
| `aws_instance.bot` (`var.instance_type`, Ubuntu 24.04, IMDSv2, termination protection) | The bot, the API and the live feed. The smallest type that may fit (t3.small since 2026-11-27, watched by the CPU and heartbeat alarms); resizing is a change of `instance_type` alone, applied while flat (the apply stops and starts the server; disks and address stay). CPU credits `unlimited`: never throttled; CPU above t3's baseline is billed extra (at most about $0.05 per vCPU-hour). |
| `aws_ebs_volume.data` (gp3, encrypted, `prevent_destroy`) at `/srv/tickr/data` | The data folder: SQLite, archives, Webull token. Separate from the root disk so the server can be rebuilt without it. |
| `aws_dlm_lifecycle_policy.data` | One snapshot a night at `snapshot_time_utc`, `snapshot_keep_days` kept. Crash-consistent (like pulling the power): SQLite recovers from its WAL, and the time is outside every session, when the bot is not running. The bot's own daily backup stays the consistent copy. |
| `aws_eip.bot` | Fixed address: the domain's A record at Namecheap and the Webull key binding. |
| `aws_security_group.bot` | Port 443 in, nothing else. No SSH: sessions through SSM. |
| `aws_secretsmanager_secret.bot_env` (`tickr-bot/env`) | The bot's credential variables, filled by the owner. A resource policy denies reading the value to every principal but the server role, account admins included (they can still write it, and change the policy on the record). This guards the API call only: anyone allowed to open an SSM session on the server gets a shell there and can read the value through the server role. CloudTrail records every session, so keep SSM session rights to the owner. |
| `aws_iam_role.bot` | SSM sessions, read of that one secret, one CloudWatch namespace (`Tickr/Bot`). Denied all SSM parameters. |
| Alarms `tickr-bot-system-check`, `tickr-bot-instance-check` | AWS hardware failure: the server is recovered onto new hardware and the owner is mailed. Operating system hung: mail only (a reboot is the owner's call while a position may be open). |
| Alarm `tickr-bot-cpu-surplus-charged` | Any hour in which CPU above the t3 baseline was billed: the signal to resize on measured load. About 0.10 USD a month (one standard alarm; owner yes 2026-11-27). |
| Metadata: hop limit 1 and `tickr-imds-block.service` | Only root's host units (secrets, heartbeat, image pull) reach the server role; the bot's containers (host networking, uid `service_uid`) are refused the metadata address. |

The training stack stays separate: the research user's rights cover only machines tagged
`tickr:role=training`, and the training machine role is denied every secret except Massive's.

## Apply (owner, on the Mac)

```sh
export AWS_PROFILE=tickr
cd ~/Development/tickr-infra/ops/aws/bot
terraform init
terraform apply -var alert_email='you@example.com'
```

Confirm the e-mail from AWS Notifications once. Commit `.terraform.lock.hcl` after the first
`terraform init`.

## Fill the secret (owner, on the Mac)

One JSON object, variable name to value, with the names the bot reads (`config/bot.toml`): the
active environment's Webull app key and secret, `TICKR_TELEGRAM_BOT_TOKEN`,
`TICKR_TELEGRAM_CHAT_ID` (Telegram is the alert channel on the server; preflight refuses
without both), and the Massive key when the live feed needs it. Write it from a file
that never enters the repo, then delete the file:

```sh
aws secretsmanager put-secret-value --secret-id tickr-bot/env --secret-string file://bot-env.json
rm -P bot-env.json
```

Never paste a value into a chat, a commit or a shell history.

If the server already runs (the usual case: the apply creates the secret empty), load the new
value once in an SSM session: `sudo systemctl restart tickr-secrets` (a reboot does the same).
Until then the bot's jobs refuse to start, as they require `tickr-secrets.service`.

## Changes on a running server

Terraform ignores a new Ubuntu image and changes to `user-data.sh` on the existing server, so an
apply never stops or replaces it. A change to the first-boot script is run once through SSM
while the bot is flat, or the server is rebuilt on a weekend while flat: turn off termination
protection, `terraform apply -replace=aws_instance.bot`; the data disk and address stay. After a
rebuild, check in an SSM session that `cloud-init status --long` says `done` (the script is
passed gzipped since tickr-infra #7) and rerun the metadata-block checks below.

### Metadata block on the server already running (once, while flat)

The hop limit changes in place with `terraform apply`. The uid rule (`files/tickr-imds-block.service`)
arrived after the first boot, so install it once through SSM:
```sh
cd ~/Development/tickr-infra/ops/aws/bot && export AWS_PROFILE=tickr
IID=$(terraform output -raw instance_id)
UID_=$(terraform output -raw service_uid)
B=$(base64 < files/tickr-imds-block.service | tr -d '\n')
ID=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters "commands=[\"echo $B | base64 -d > /etc/systemd/system/tickr-imds-block.service\",\"echo TICKR_SERVICE_UID=$UID_ > /srv/tickr/etc/uid.env\",\"systemctl daemon-reload\",\"systemctl enable --now tickr-imds-block.service\",\"iptables -S OUTPUT | grep 169.254.169.254\",\"sudo -u tickr curl -s -m 3 http://169.254.169.254/ || echo blocked-for-tickr\"]" \
  --query Command.CommandId --output text)
sleep 10; aws ssm get-command-invocation --command-id "$ID" --instance-id "$IID" --query '[Status,StandardOutputContent]' --output text
```
The output must show the REJECT rule and `blocked-for-tickr`. The rule fails open (no rule if the
unit or `uid.env` is missing, and nothing alerts), so run the same two checks again after every
rebuild of the server:
```sh
ID=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters 'commands=["iptables -S OUTPUT | grep 169.254.169.254","sudo -u tickr curl -s -m 3 http://169.254.169.254/ || echo blocked-for-tickr"]' \
  --query Command.CommandId --output text)
sleep 10; aws ssm get-command-invocation --command-id "$ID" --instance-id "$IID" --query '[Status,StandardOutputContent]' --output text
```

## Runtime on the server (first boot)

`user-data.sh` also installs the files in `files/`:

- `tickr-secrets` and `tickr-secrets.service`: at every boot, before the bot's jobs (their units
  carry `Requires=`/`After=tickr-secrets.service`), the secret is written to `/run/tickr/env`,
  mode 600, owner `tickr`, in the `NAME='value'` form the container entrypoint sources. `/run`
  is memory: the file never reaches the disk or its snapshots. The script refuses, writing
  nothing, a secret that is not a JSON object of names to non-empty strings, or a value holding
  `'` or a newline. It never prints a value.
- Caddy (`Caddyfile`, drop-in `caddy-tickr.conf`): HTTPS for `bot_domain` in front of the API's
  remote port, certificate from Let's Encrypt through the TLS-ALPN challenge on 443. Caddy
  forwards the original Host, so the API's `remote_hosts_file` (in the data folder) must list
  the domain, as it lists the Tailscale name on the Mac. Installed but off, with port 443 closed,
  until the API is exposed (below).
- `tickr-heartbeat` with a one-minute timer: one CloudWatch point (`Tickr/Bot` `Heartbeat`) while
  the server and its local API answer. Alarm `tickr-bot-heartbeat` mails the owner after
  `heartbeat_missing_minutes` without one.

Caddy and the heartbeat read `/srv/tickr/etc/ports.env` (`TICKR_API_PORT`,
`TICKR_API_REMOTE_PORT`), which `render-systemd` writes from `config/bot.toml` on the first
deploy, so the ports have one source. Until then both fail and the heartbeat alarm is on.

## Expose the API

Off by default: with port 443 open, a device token is the only barrier in front of operator
commands, where on the Mac the tailnet stands in front of it too. Turn it on only when the API
refuses repeated bad tokens per address (it does: `[api] remote_auth_*`, docs/api.md "Failed
authentication limit", keyed on the last `X-Forwarded-For` entry Caddy sets), its error paths
leak nothing, and the owner has decided which commands may be reached from the internet. Then:

1. `terraform apply -var expose_api=true ...` opens 443.
2. In an SSM session on the server: `sudo systemctl enable --now caddy`.
3. Add the `bot_domain` A record at the registrar, pointing at `server_address`.

## Release image

`image.tf` adds the registry `tickr-bot` (immutable tags, scanned on push, the newest
`images_kept` kept) and the role `tickr-image-push`, which only a workflow run on `main` of
`github_repo` can assume through GitHub's OIDC token: no AWS key is stored in GitHub. After the
apply, the owner sets the repository variable once (a variable, not a secret: an ARN is not a
credential):

```sh
gh variable set AWS_IMAGE_PUSH_ROLE --repo tickr-devs/tickr-bot --body "$(terraform output -raw image_push_role)"
```

From then on tickr-bot's `.github/workflows/server-image.yml` builds every change on main that touches the
image and pushes `tickr-bot:<commit>`. The server pulls with its own role (pull only). The
image's user has uid and gid `service_uid` (1500), the same as the server's `tickr` account.
A test (`tests/ops/test_server_uid.py`) keeps the two values equal. A re-run for a commit
already pushed skips the push, since tags are immutable. The job log shows the registry host,
which contains the account number: not a credential.

An account holds one OIDC provider per URL. If one for `token.actions.githubusercontent.com`
already exists, the first apply stops on it; import it once and apply again:

```sh
terraform import aws_iam_openid_connect_provider.github \
  "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):oidc-provider/token.actions.githubusercontent.com"
```

## Release on the server

A server created before `tickr-image-pull` and `registry.env` existed (the first one, 2026-11-26)
gets them once, from the Mac in `ops/aws/bot` (the script travels base64-encoded; no secret is in
it):

```sh
aws ssm send-command --instance-ids "$(terraform output -raw instance_id)" \
  --document-name AWS-RunShellScript --parameters commands="echo TICKR_IMAGE_REPOSITORY=$(terraform output -raw image_repository) > /srv/tickr/etc/registry.env && chmod 644 /srv/tickr/etc/registry.env && echo $(base64 < files/tickr-image-pull | tr -d '\n') | base64 -d > /usr/local/bin/tickr-image-pull && chmod 755 /usr/local/bin/tickr-image-pull"
```

Then, for each release:

In an SSM session, with the full commit of main whose image CI pushed:

```sh
sudo tickr-image-pull <commit>     # pull it and mark it release-<commit> in the registry
sudo /srv/tickr/bin/deploy-server.sh <commit>       # refuses unless flat (docs/deploy-server.md)
```

`tickr-image-pull` reads the repository from `/srv/tickr/etc/registry.env` (written at first
boot from the stack) and signs in to the registry only for that run. The registry keeps the newest
`images_kept` commit images and, separately, the newest `releases_kept` deployed releases: an
image tagged `release-…` is never expired by the commit-count rule, so a rollback or a rebuilt
server can always pull it. The server role may add a tag to an image already in the registry,
but cannot upload layers or delete; tags are immutable.
