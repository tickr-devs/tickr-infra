#!/bin/sh
# Moves the bot's data folder to a new, smaller data disk (EBS cannot shrink a disk). The owner
# runs it on the Mac in ops/aws/bot with AWS_PROFILE set, when only the API and the watchdog run
# (after 20:00 ET or at the weekend; README, "Smaller data disk"):
#
#     sh move-data-disk.sh 30
#
# 0. On the server (SSM), read-only: refuse unless the old disk is the data folder and only the
#    API and the watchdog run. A refusal here leaves nothing behind.
# 1. Snapshot of the old disk (kept until the new one has run a few days).
# 2. New encrypted gp3 disk of SIZE_GB, tagged like the old one, attached as a second disk.
# 3. On the server: the same checks again; format the new disk, stop the active tickr units and
#    Docker, copy the folder, compare checksums of every file, point /etc/fstab at the new disk.
# 4. Detach both disks, attach the new one where the old one was (/dev/sdf).
# 5. On the server: mount it, start Docker and the units that were active, check the containers
#    that ran before run again. Remove the nightly-snapshot tag from the old disk.
#
# The old disk stays detached and the snapshot kept; nothing is deleted here. Afterwards Terraform
# is pointed at the new disk (README).
#
# A failure in step 3 puts the old disk back at /srv/tickr/data and restarts Docker and the units
# by itself. A stop after step 3 (/etc/fstab already names the new disk) is finished by hand:
# (a) forward: attach the new disk at /dev/sdf if it is not
#     (`aws ec2 attach-volume --volume-id NEW --instance-id IID --device /dev/sdf`), then in an SSM
#     session `mountpoint -q /srv/tickr/data || mount /srv/tickr/data`,
#     `systemctl start docker.socket docker.service`, `systemctl start $(cat /srv/tickr/etc/move-units)`;
# (b) or back: detach the new disk, attach the old one at /dev/sdf, put the old UUID (`blkid` of
#     the old disk) back on the /srv/tickr/data line of /etc/fstab, then the same three commands.
# On any stop the script prints what it left behind (snapshot, new disk, attachments). Read that
# and the README's "If the move stops" before anything else; never re-run first (each run makes a
# new snapshot and a new disk).
set -eu
SIZE_GB=${1:?usage: sh move-data-disk.sh SIZE_GB}
: "${AWS_PROFILE:?set AWS_PROFILE}"
IID=$(terraform output -raw instance_id)
OLD=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$IID" "Name=attachment.device,Values=/dev/sdf" \
  --query 'Volumes[0].VolumeId' --output text)
case "$OLD" in vol-*) ;; *) echo "no data disk at /dev/sdf"; exit 1 ;; esac
AZ=$(aws ec2 describe-volumes --volume-ids "$OLD" --query 'Volumes[0].AvailabilityZone' --output text)
echo "server $IID, old disk $OLD ($AZ), new size $SIZE_GB GB"

TMP=$(mktemp -d)
SNAP=''
NEW=''
DONE=''
# On any stop: what exists now, so nothing paid is left behind unseen.
left_behind() {
  [ -n "$DONE" ] && return
  echo "STOPPED. Left behind: snapshot ${SNAP:-none}, new disk ${NEW:-none}. Disks now:"
  aws ec2 describe-volumes --volume-ids "$OLD" ${NEW:+"$NEW"} \
    --query 'Volumes[].[VolumeId,Size,State,Attachments[0].Device]' --output text || true
  echo "Read the README's 'If the move stops' before anything else. Do not re-run first."
}
trap left_behind EXIT

# Runs a shell script on the server as root; prints its output, fails unless it succeeded. Waits
# for the end however long the copy takes (the CLI waiter gives up after 100 s; SSM ends a command
# after its 3600 s execution timeout). Only "not registered yet" is waited out; any other error
# of the read stops the move.
on_server() {
  b=$(printf '%s\n' "$1" | base64 | tr -d '\n')
  cid=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
    --parameters "commands=[\"echo $b | base64 -d | bash\"]" --query Command.CommandId --output text)
  while :; do
    sleep 5
    if ! st=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$IID" --query Status --output text 2>"$TMP/err"); then
      grep -q InvocationDoesNotExist "$TMP/err" && continue
      cat "$TMP/err"
      return 1
    fi
    case "$st" in Pending | InProgress | Delayed) ;; *) break ;; esac
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$IID" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text | tee "$TMP/out"
  [ "$st" = Success ]
}

OLD_DEV=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$(echo "$OLD" | tr -d -)
# Read-only checks first, so a refusal leaves nothing behind: the old disk is the data folder, and
# nothing but the API and the watchdog runs (the watchdog is started again after the move).
on_server "set -eu
[ \"\$(findmnt -n -o SOURCE /srv/tickr/data)\" = \"\$(readlink -f $OLD_DEV)\" ] || { echo 'old disk not at /srv/tickr/data'; exit 1; }
others=\$(docker ps --format '{{.Label \"com.docker.compose.service\"}}' | grep -vx -e api -e watchdog || true)
[ -z \"\$others\" ] || { echo \"refused: running besides the API and the watchdog: \$others (run after 20:00 ET or at the weekend)\"; exit 1; }
echo checks passed"

SNAP=$(aws ec2 create-snapshot --volume-id "$OLD" --description "tickr-bot-data before the move" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=tickr-bot-data-before-move},{Key=tickr:stack,Value=bot}]' \
  --query SnapshotId --output text)
aws ec2 wait snapshot-completed --snapshot-ids "$SNAP"
echo "snapshot $SNAP done"

NEW=$(aws ec2 create-volume --availability-zone "$AZ" --size "$SIZE_GB" --volume-type gp3 --encrypted \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=tickr-bot-data},{Key=tickr:role,Value=bot},{Key=tickr:backup,Value=nightly},{Key=tickr:stack,Value=bot}]' \
  --query VolumeId --output text)
aws ec2 wait volume-available --volume-ids "$NEW"
aws ec2 attach-volume --volume-id "$NEW" --instance-id "$IID" --device /dev/sdg >/dev/null
aws ec2 wait volume-in-use --volume-ids "$NEW"
echo "new disk $NEW attached"

NEW_DEV=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$(echo "$NEW" | tr -d -)
STATE=/srv/tickr/etc

# Server function: starts Docker and the saved units, then every container that ran before the
# move and is not running (bot and watchdog are not restarted by Docker); fails naming any still
# missing.
START="start_all() {
  systemctl start docker.socket docker.service
  units=\$(cat $STATE/move-units)
  [ -z \"\$units\" ] || systemctl start \$units
  for c in \$(cat $STATE/move-containers); do
    docker ps --format '{{.Names}}' | grep -qx \"\$c\" || docker start \"\$c\" >/dev/null || true
  done
  missing=''
  for c in \$(cat $STATE/move-containers); do
    docker ps --format '{{.Names}}' | grep -qx \"\$c\" || missing=\"\$missing \$c\"
  done
  echo \"units started: \$units\"
  echo \"containers running: \$(docker ps --format '{{.Names}}' | tr '\\n' ' ')\"
  [ -z \"\$missing\" ] || { echo \"NOT RUNNING:\$missing\"; return 1; }
}"

on_server "set -eEu
$START
for _ in \$(seq 1 60); do [ -e $NEW_DEV ] && break; sleep 2; done
[ -e $NEW_DEV ] || { echo 'new disk not visible'; exit 1; }
if blkid $NEW_DEV; then echo 'new disk already holds a filesystem'; exit 1; fi
[ \"\$(findmnt -n -o SOURCE /srv/tickr/data)\" = \"\$(readlink -f $OLD_DEV)\" ] || { echo 'old disk not at /srv/tickr/data'; exit 1; }
others=\$(docker ps --format '{{.Label \"com.docker.compose.service\"}}' | grep -vx -e api -e watchdog || true)
[ -z \"\$others\" ] || { echo \"refused: running besides the API and the watchdog: \$others (run after 20:00 ET or at the weekend)\"; exit 1; }
docker ps --format '{{.Names}}' > $STATE/move-containers
systemctl list-units 'tickr-*' --state=active --plain --no-legend | awk '{print \$1}' \
  | grep -v -e '^tickr-heartbeat' -e '^tickr-secrets' -e '^tickr-imds-block' > $STATE/move-units || true
# Until /etc/fstab names the new disk: any failure puts the old disk back and restarts the bot.
# Each step goes on when one before it fails, so the bot gets as far back as it can.
restore() {
  echo 'FAILED: restoring the old disk and the bot'
  if mountpoint -q /mnt/tickr-new; then umount /mnt/tickr-new || echo 'could not unmount the new disk'; fi
  mountpoint -q /srv/tickr/data || mount /srv/tickr/data || echo 'could not mount the old disk'
  start_all || echo 'could not start everything: see above'
}
trap restore ERR
mkfs.ext4 -q -L tickr-data $NEW_DEV
install -d /mnt/tickr-new
mount $NEW_DEV /mnt/tickr-new
units=\$(cat $STATE/move-units)
[ -z \"\$units\" ] || systemctl stop \$units
systemctl stop docker.socket docker.service
cp -a /srv/tickr/data/. /mnt/tickr-new/
sums() { (cd \"\$1\" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum); }
sums /srv/tickr/data > /root/move-old.sha256
sums /mnt/tickr-new > /root/move-new.sha256
old_n=\$(cd /srv/tickr/data && find . | wc -l); new_n=\$(cd /mnt/tickr-new && find . | wc -l)
echo \"entries \$old_n -> \$new_n, files checked: \$(wc -l < /root/move-old.sha256)\"
[ \"\$old_n\" = \"\$new_n\" ] || { echo 'entry count differs'; false; }
cmp -s /root/move-old.sha256 /root/move-new.sha256 || { echo 'checksums differ'; false; }
old_uuid=\$(blkid -s UUID -o value $OLD_DEV); new_uuid=\$(blkid -s UUID -o value $NEW_DEV)
umount /mnt/tickr-new
umount /srv/tickr/data
sed -i \"s/^UUID=\$old_uuid /UUID=\$new_uuid /\" /etc/fstab
grep -q \"^UUID=\$new_uuid /srv/tickr/data \" /etc/fstab
trap - ERR
systemctl daemon-reload
# systemd may mount the new fstab line by itself now; both disks must be free to detach.
udevadm settle
sleep 5
if mountpoint -q /srv/tickr/data; then umount /srv/tickr/data; fi
echo copied"

aws ec2 detach-volume --volume-id "$OLD" >/dev/null
aws ec2 detach-volume --volume-id "$NEW" >/dev/null
aws ec2 wait volume-available --volume-ids "$OLD" "$NEW"
aws ec2 attach-volume --volume-id "$NEW" --instance-id "$IID" --device /dev/sdf >/dev/null
aws ec2 wait volume-in-use --volume-ids "$NEW"

on_server "set -eu
$START
for _ in \$(seq 1 60); do [ -e $NEW_DEV ] && break; sleep 2; done
mountpoint -q /srv/tickr/data || mount /srv/tickr/data
[ \"\$(findmnt -n -o SOURCE /srv/tickr/data)\" = \"\$(readlink -f $NEW_DEV)\" ]
chown tickr:tickr /srv/tickr/data
chmod 700 /srv/tickr/data
start_all
rm $STATE/move-units $STATE/move-containers /root/move-old.sha256 /root/move-new.sha256
df -h /srv/tickr/data"

aws ec2 delete-tags --resources "$OLD" --tags Key=tickr:backup
DONE=1
echo "done: new disk $NEW at /dev/sdf, old disk $OLD detached (kept, nightly tag removed), snapshot $SNAP"
echo "next (README): terraform state pull > ~/state-before-move.json"
echo "  terraform state rm aws_volume_attachment.data aws_ebs_volume.data"
echo "  terraform import aws_ebs_volume.data $NEW"
echo "  terraform import aws_volume_attachment.data /dev/sdf:$NEW:$IID"
