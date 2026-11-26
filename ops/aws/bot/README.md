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
| `aws_instance.bot` (`var.instance_type`, Ubuntu 24.04, IMDSv2, termination protection) | The bot, the API and the live feed. Starts small (t3.medium); growing it is a change of `instance_type` alone, applied on a weekend while flat (the apply stops and starts the server; disks and address stay). CPU credits `unlimited`: never throttled; CPU above t3's baseline is billed extra (at most about $0.05 per vCPU-hour). |
| `aws_ebs_volume.data` (gp3, encrypted, `prevent_destroy`) at `/srv/tickr/data` | The data folder: SQLite, archives, Webull token. Separate from the root disk so the server can be rebuilt without it. |
| `aws_dlm_lifecycle_policy.data` | One snapshot a night at `snapshot_time_utc`, `snapshot_keep_days` kept. Crash-consistent (like pulling the power): SQLite recovers from its WAL, and the time is outside every session, when the bot is not running. The bot's own daily backup stays the consistent copy. |
| `aws_eip.bot` | Fixed address: the domain's A record at Namecheap and the Webull key binding. |
| `aws_security_group.bot` | Port 443 in, nothing else. No SSH: sessions through SSM. |
| `aws_secretsmanager_secret.bot_env` (`tickr-bot/env`) | The bot's credential variables, filled by the owner. A resource policy denies reading the value to every principal but the server role, account admins included (they can still write it, and change the policy on the record). |
| `aws_iam_role.bot` | SSM sessions, read of that one secret, one CloudWatch namespace (`Tickr/Bot`). Denied all SSM parameters. |
| Alarms `tickr-bot-system-check`, `tickr-bot-instance-check` | AWS hardware failure: the server is recovered onto new hardware and the owner is mailed. Operating system hung: mail only (a reboot is the owner's call while a position may be open). |

The training stack stays separate: the research user's rights cover only machines tagged
`tickr:role=training`, and the training machine role is denied every secret except Massive's.

## Apply (owner, on the Mac)

```sh
export AWS_PROFILE=tickr
cd ~/Development/Tickr/ops/aws/bot
terraform init
terraform apply -var alert_email='you@example.com'
```

Confirm the e-mail from AWS Notifications once. Commit `.terraform.lock.hcl` after the first
`terraform init`.

## Fill the secret (owner, on the Mac)

One JSON object, variable name to value, with the names the bot reads (`config/bot.toml`): the
active environment's Webull app key and secret, `TICKR_TELEGRAM_BOT_TOKEN`,
`TICKR_TELEGRAM_CHAT_ID`, and the Massive key when the live feed needs it. Write it from a file
that never enters the repo, then delete the file:

```sh
aws secretsmanager put-secret-value --secret-id tickr-bot/env --secret-string file://bot-env.json
rm -P bot-env.json
```

Never paste a value into a chat, a commit or a shell history.

## Changes on a running server

Terraform ignores a new Ubuntu image and changes to `user-data.sh` on the existing server, so an
apply never stops or replaces it. A change to the first-boot script is run once through SSM
while the bot is flat, or the server is rebuilt on a weekend while flat: turn off termination
protection, `terraform apply -replace=aws_instance.bot`; the data disk and address stay.
