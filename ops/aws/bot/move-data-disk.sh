#!/bin/sh
# Moves the bot's data folder to a new, smaller data disk (EBS cannot shrink a disk). The owner
# runs it on the Mac in ops/aws/bot with AWS_PROFILE set, only while the bot is flat:
#
#     sh move-data-disk.sh 30
#
# 1. Snapshot of the old disk (kept until the new one has run a week).
# 2. New encrypted gp3 disk of SIZE_GB, tagged like the old one, attached as a second disk.
# 3. On the server (SSM): format it, stop the bot's units and Docker, copy the folder, compare
#    file counts and sizes, point /etc/fstab at the new disk.
# 4. Detach both disks, attach the new one where the old one was (/dev/sdf).
# 5. On the server: mount it, start Docker and the units that were running.
#
# The old disk stays detached, never deleted here. Afterwards Terraform is pointed at the new disk
# (README, "Smaller data disk"). On a failure before step 4 the old disk is still in /etc/fstab:
# in an SSM session, `mount /srv/tickr/data && systemctl start docker` puts things back.
set -eu
SIZE_GB=${1:?usage: sh move-data-disk.sh SIZE_GB}
: "${AWS_PROFILE:?set AWS_PROFILE}"
IID=$(terraform output -raw instance_id)
OLD=$(terraform output -raw data_volume_id)
AZ=$(aws ec2 describe-volumes --volume-ids "$OLD" --query 'Volumes[0].AvailabilityZone' --output text)
echo "server $IID, old disk $OLD ($AZ), new size $SIZE_GB GB"

# Runs a shell script on the server as root; prints its output, fails unless it succeeded.
on_server() {
  b=$(printf '%s\n' "$1" | base64 | tr -d '\n')
  cid=$(aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
    --parameters "commands=[\"echo $b | base64 -d | bash\"]" --query Command.CommandId --output text)
  # Waits for the end however long the copy takes (the CLI waiter gives up after 100 s).
  while :; do
    sleep 5
    st=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$IID" --query Status --output text 2>/dev/null || echo Pending)
    case "$st" in Pending | InProgress | Delayed) ;; *) break ;; esac
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$IID" \
    --query '[Status,StandardOutputContent,StandardErrorContent]' --output text | tee move-step.out
  head -1 move-step.out | grep -q '^Success' && rm move-step.out
}

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

OLD_DEV=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$(echo "$OLD" | tr -d -)
NEW_DEV=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$(echo "$NEW" | tr -d -)
on_server "set -eu
for _ in \$(seq 1 60); do [ -e $NEW_DEV ] && break; sleep 2; done
[ -e $NEW_DEV ] || { echo 'new disk not visible'; exit 1; }
if blkid $NEW_DEV; then echo 'new disk already holds a filesystem'; exit 1; fi
[ \"\$(findmnt -n -o SOURCE /srv/tickr/data)\" = \"\$(readlink -f $OLD_DEV)\" ] || { echo 'old disk not at /srv/tickr/data'; exit 1; }
mkfs.ext4 -q -L tickr-data $NEW_DEV
install -d /mnt/tickr-new
mount $NEW_DEV /mnt/tickr-new
units=\$(systemctl list-units 'tickr-*' --state=active --plain --no-legend | awk '{print \$1}' | grep -v -e '^tickr-heartbeat' -e '^tickr-secrets' -e '^tickr-imds-block' || true)
echo \"\$units\" > /srv/tickr/etc/move-units
[ -z \"\$units\" ] || systemctl stop \$units
systemctl stop docker.socket docker.service
cp -a /srv/tickr/data/. /mnt/tickr-new/
old_n=\$(find /srv/tickr/data | wc -l); new_n=\$(find /mnt/tickr-new | wc -l)
old_b=\$(find /srv/tickr/data -type f -printf '%s\\n' | awk '{s+=\$1} END {print s+0}')
new_b=\$(find /mnt/tickr-new -type f -printf '%s\\n' | awk '{s+=\$1} END {print s+0}')
echo \"files \$old_n -> \$new_n, bytes \$old_b -> \$new_b\"
[ \"\$old_n\" = \"\$new_n\" ] && [ \"\$old_b\" = \"\$new_b\" ] || { echo 'copy differs: old disk kept, bot restarted'; umount /mnt/tickr-new; systemctl start docker.socket docker.service; [ -z \"\$units\" ] || systemctl start \$units; exit 1; }
old_uuid=\$(blkid -s UUID -o value $OLD_DEV); new_uuid=\$(blkid -s UUID -o value $NEW_DEV)
umount /mnt/tickr-new
umount /srv/tickr/data
sed -i \"s/^UUID=\$old_uuid /UUID=\$new_uuid /\" /etc/fstab
grep -q \"^UUID=\$new_uuid /srv/tickr/data \" /etc/fstab
systemctl daemon-reload
echo copied"

aws ec2 detach-volume --volume-id "$OLD" >/dev/null
aws ec2 detach-volume --volume-id "$NEW" >/dev/null
aws ec2 wait volume-available --volume-ids "$OLD" "$NEW"
aws ec2 attach-volume --volume-id "$NEW" --instance-id "$IID" --device /dev/sdf >/dev/null
aws ec2 wait volume-in-use --volume-ids "$NEW"

on_server "set -eu
for _ in \$(seq 1 60); do [ -e $NEW_DEV ] && break; sleep 2; done
mount /srv/tickr/data
[ \"\$(findmnt -n -o SOURCE /srv/tickr/data)\" = \"\$(readlink -f $NEW_DEV)\" ]
chown tickr:tickr /srv/tickr/data
chmod 700 /srv/tickr/data
systemctl start docker.socket docker.service
units=\$(cat /srv/tickr/etc/move-units)
[ -z \"\$units\" ] || systemctl start \$units
rm /srv/tickr/etc/move-units
df -h /srv/tickr/data
echo \"started: \$units\""

echo "done: new disk $NEW, old disk $OLD detached (kept), snapshot $SNAP"
echo "next (README): terraform state rm aws_volume_attachment.data aws_ebs_volume.data"
echo "  terraform import aws_ebs_volume.data $NEW"
echo "  terraform import aws_volume_attachment.data /dev/sdf:$NEW:$IID"
