#!/bin/bash
# First boot of the bot server. Holds no secret: tickr-secrets.service reads the bot's
# credentials from Secrets Manager into memory (/run/tickr/env) at each boot. Re-running this
# script is safe.
# Terraform ignores changes to it on a running server (main.tf); apply a change through SSM.
set -eu

apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 chrony unzip curl caddy python3
# Caddy stays off until the API is exposed (README, "Expose the API"); the package starts it.
systemctl disable --now caddy.service

# Clock: Amazon Time Sync, the link-local NTP server of every EC2 host. The bot refuses quotes
# more than [risk] max_clock_skew_seconds away from its clock.
cat > /etc/chrony/sources.d/amazon-time-sync.sources <<'NTP'
server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4
NTP
systemctl restart chrony

# AWS CLI: pinned version, refused unless its sha256 matches (variable "installers").
if ! command -v aws >/dev/null; then
  curl -sSfL https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${aws_cli_version}.zip -o /tmp/awscli.zip
  echo "${aws_cli_sha256}  /tmp/awscli.zip" | sha256sum -c -
  unzip -q /tmp/awscli.zip -d /tmp
  /tmp/aws/install
fi

# Service account that runs the containers and owns the data (docs/deploy-server.md).
# Fixed uid and gid: the release image is built with the same ones (TICKR_UID/TICKR_GID in
# .github/workflows/server-image.yml), so the container user can read /run/tickr/env (mode 600).
getent group tickr >/dev/null || groupadd --gid ${service_uid} tickr
id tickr >/dev/null 2>&1 || useradd --uid ${service_uid} --gid ${service_uid} --create-home --shell /usr/sbin/nologin tickr
usermod -aG docker tickr
install -d -m 755 /srv/tickr
install -d -m 700 -o tickr -g tickr /srv/tickr/etc

# Data disk: found by its volume id, formatted only when it holds no filesystem yet (first boot
# of a new disk), mounted by UUID. An existing filesystem is never formatted.
DEV=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$(echo ${data_volume_id} | tr -d -)
for _ in $(seq 1 60); do [ -e "$DEV" ] && break; sleep 5; done
[ -e "$DEV" ] || { echo "data disk ${data_volume_id} not attached"; exit 1; }
if ! blkid "$DEV" >/dev/null; then
  mkfs.ext4 -q -L tickr-data "$DEV"
fi
UUID=$(blkid -s UUID -o value "$DEV")
install -d -m 755 /srv/tickr/data
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /srv/tickr/data ext4 defaults,nofail 0 2" >> /etc/fstab
mountpoint -q /srv/tickr/data || mount /srv/tickr/data
chown tickr:tickr /srv/tickr/data
chmod 700 /srv/tickr/data

# Runtime files (files/ in the repo).
put() { echo "$2" | base64 -d > "$1"; chmod "$3" "$1"; }
put /usr/local/bin/tickr-secrets '${files["tickr-secrets"]}' 755
put /etc/systemd/system/tickr-secrets.service '${files["tickr-secrets.service"]}' 644
put /usr/local/bin/tickr-heartbeat '${files["tickr-heartbeat"]}' 755
put /usr/local/bin/tickr-image-pull '${files["tickr-image-pull"]}' 755
put /etc/systemd/system/tickr-heartbeat.service '${files["tickr-heartbeat.service"]}' 644
put /etc/systemd/system/tickr-heartbeat.timer '${files["tickr-heartbeat.timer"]}' 644
put /etc/caddy/Caddyfile '${files["Caddyfile"]}' 644
install -d /etc/systemd/system/caddy.service.d
put /etc/systemd/system/caddy.service.d/tickr.conf '${files["caddy-tickr.conf"]}' 644
echo "TICKR_DOMAIN=${bot_domain}" > /srv/tickr/etc/domain.env
chmod 644 /srv/tickr/etc/domain.env
# Region for the AWS CLI in tickr-secrets and tickr-heartbeat, so it never depends on a lookup.
echo "AWS_DEFAULT_REGION=${region}" > /srv/tickr/etc/aws.env
chmod 644 /srv/tickr/etc/aws.env
# Where release images come from (not a secret); tickr-image-pull and deploy-server.sh read it.
echo "TICKR_IMAGE_REPOSITORY=${image_repository}" > /srv/tickr/etc/registry.env
chmod 644 /srv/tickr/etc/registry.env

systemctl daemon-reload
# The heartbeat needs /srv/tickr/etc/ports.env, written by the first deploy (render-systemd);
# until then it fails and the heartbeat alarm stays on, as it should. It runs on the host,
# not in a container, so it reaches the instance role with the metadata hop limit of 1.
systemctl enable --now tickr-heartbeat.timer
# On the first boot the secret is still empty (the owner fills it after the apply), so
# tickr-secrets fails and the bot's jobs refuse to start (Requires=). That must not end this
# script: it is started last and its failure only noted. After filling the secret the owner
# runs `sudo systemctl restart tickr-secrets` once (README).
systemctl enable tickr-secrets.service
systemctl start tickr-secrets.service || echo "tickr-secrets: secret not filled yet"

