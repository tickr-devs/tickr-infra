# Account stack (AWS): account-wide safety settings

From the AWS setup audit of 2026-11-26. Separate from `bot`, `web` and `training`, which own only
their own resources; the account budget stays in `ops/aws/training`.

What it creates:
- **EBS encryption by default**: every new disk in us-east-1 is encrypted (AWS-managed key).
  Free. Existing disks are not touched (they are all encrypted already).
- **CloudTrail `tickr-audit`**: every management API call in every region (who, what, from
  which address), in the private bucket `tickr-audit-<account id>` (TLS only, encrypted, files
  deleted after `audit_log_keep_days`, 365), with log-file validation. The first trail of
  management events is free; storage is cents a month.
- **GuardDuty** (only with `guardduty_enabled = true`): flags a stolen key used from an unusual
  place, crypto-mining, port scans and the like, and mails findings of severity
  `guardduty_min_severity` (4, medium) and up. Priced by the account's events and traffic: a few
  USD a month here. Off until the owner says yes on that sum.

## Apply (owner, on the Mac)

```sh
cd ~/Development/Tickr && git switch main && git pull
cd ops/aws/account && export AWS_PROFILE=tickr
terraform init
aws cloudtrail describe-trails --include-shadow-trails   # must list nothing, or the trail is a billed second copy
terraform plan
terraform apply
```
With GuardDuty, add `-var guardduty_enabled=true -var alert_email='you@example.com'` to both commands and confirm the link AWS mails.

Read the log: CloudTrail > Event history in the console (90 days), or the files in the bucket.
