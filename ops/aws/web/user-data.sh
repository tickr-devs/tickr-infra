#!/bin/bash
# First boot of the tickr.bot web server (Terraform template: ${domain}, ${bucket}, ${region},
# ${service_uid}, ${aws_cli_version}, ${aws_cli_sha256}).
# Installs Docker and the AWS CLI, creates the service account and the folders, generates the
# app's secret key and database password ON the machine (they never leave it), and installs
# tickr-web-deploy, which ship.sh runs over SSM for each release.
set -eu
apt-get update -q
apt-get install -y -q docker.io docker-compose-v2 rsync unzip

# Swap file (variable swap_gb): headroom for image builds on the small machine.
if [ ! -f /swapfile ]; then
  fallocate -l ${swap_gb}G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
swapon --show | grep -q /swapfile || swapon /swapfile
systemctl enable --now docker

# AWS CLI in /usr/local/bin (on every PATH, systemd units and SSM included): pinned version,
# refused unless its sha256 matches (variable "installers").
if ! command -v aws >/dev/null; then
  cli=$(mktemp -d)
  curl -sSfL https://awscli.amazonaws.com/awscli-exe-linux-aarch64-${aws_cli_version}.zip -o "$cli/awscli.zip"
  echo "${aws_cli_sha256}  $cli/awscli.zip" | sha256sum -c -
  unzip -q "$cli/awscli.zip" -d "$cli"
  "$cli/aws/install"
  rm -rf -- "$cli"
fi

# Service account: owns the secrets (mode 600) and runs compose. Its uid is the image's user
# (USER in web/Dockerfile, variable service_uid), so the app container can read the two files.
groupadd --system --gid ${service_uid} tickrweb
useradd --system --uid ${service_uid} --gid ${service_uid} --create-home --home-dir /srv/tickr-web --shell /usr/sbin/nologin --groups docker tickrweb
install -d -o tickrweb -g tickrweb -m 755 /srv/tickr-web/site /srv/tickr-web/repo
install -d -o tickrweb -g tickrweb -m 700 /srv/tickr-web/etc

umask 077
if [ ! -f /srv/tickr-web/etc/env ]; then
  key=$(python3 -c 'import secrets; print(secrets.token_urlsafe(50))')
  cat > /srv/tickr-web/etc/env <<ENV
TICKR_WEB_HOST='${domain}'
TICKR_WEB_SECRET_KEY='$key'
TICKR_WEB_FROM_EMAIL='tickr.bot <hello@${domain}>'
TICKR_WEB_SES_REGION='${region}'
ENV
  unset key
fi
if [ ! -f /srv/tickr-web/etc/db_password ]; then
  python3 -c 'import secrets; print(secrets.token_urlsafe(32), end="")' > /srv/tickr-web/etc/db_password
fi
cat > /srv/tickr-web/etc/compose.env <<ENV
TICKR_WEB_HOST=${domain}
TICKR_WEB_ENV_FILE_HOST=/srv/tickr-web/etc/env
TICKR_WEB_DB_PASSWORD_FILE_HOST=/srv/tickr-web/etc/db_password
TICKR_WEB_SITE_DIR=/srv/tickr-web/site
TICKR_WEB_BACKUP_BUCKET=${bucket}
ENV
chown tickrweb:tickrweb /srv/tickr-web/etc/*
umask 022

cat > /usr/local/bin/tickr-web-deploy <<'DEPLOY'
#!/bin/bash
# tickr-web-deploy APP_KEY [SITE_KEY]: install a release ship.sh uploaded to s3://BUCKET/releases/.
# APP_KEY is a tarball of the repo's web/ folder; SITE_KEY (optional) one of the built public site.
set -eu
bucket=$(sed -n 's/^TICKR_WEB_BACKUP_BUCKET=//p' /srv/tickr-web/etc/compose.env)
work=$(mktemp -d /var/tmp/tickr-web-release.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
aws s3 cp "s3://$bucket/releases/$1" "$work/app.tgz" --only-show-errors
mkdir "$work/web"
tar -xzf "$work/app.tgz" -C "$work/web"
if [ -n "$${2:-}" ]; then
  aws s3 cp "s3://$bucket/releases/$2" "$work/site.tgz" --only-show-errors
  mkdir "$work/site"
  tar -xzf "$work/site.tgz" -C "$work/site"
  rsync -a --delete "$work/site/" /srv/tickr-web/site/
fi
rsync -a --delete "$work/web/" /srv/tickr-web/repo/web/
chown -R tickrweb:tickrweb /srv/tickr-web/repo /srv/tickr-web/site
cp /srv/tickr-web/repo/web/deploy/systemd/* /etc/systemd/system/
systemctl daemon-reload
cd /srv/tickr-web/repo/web/deploy
sudo -u tickrweb sh -c 'set -a; . /srv/tickr-web/etc/compose.env; set +a
  docker compose build --pull app &&
  docker compose --profile deploy run --rm static &&
  docker compose up -d --remove-orphans &&
  docker image prune -f >/dev/null'
systemctl enable --now tickr-web.service tickr-web-backup.timer tickr-web-prune.timer
echo "deployed $1 $${2:-}"
DEPLOY
chmod 755 /usr/local/bin/tickr-web-deploy
