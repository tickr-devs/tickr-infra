#!/bin/bash
# First boot of the bot server. Holds no secret: the bot's credentials stay in Secrets Manager
# until a later step reads them into memory (/run). Re-running this script is safe.
# Terraform ignores changes to it on a running server (main.tf); apply a change through SSM.
set -eu

apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 chrony unzip curl

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
id tickr >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin tickr
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
