# Account-wide safety settings (AWS setup audit, 2026-11-26): an audit log of every API call,
# encryption of every new disk, and optional threat detection. Separate from the bot, web and
# training stacks, which each own only their own resources. The account budget stays in
# ops/aws/training (the only budget for the account).

data "aws_caller_identity" "me" {}

data "aws_partition" "current" {}

locals {
  account   = data.aws_caller_identity.me.account_id
  partition = data.aws_partition.current.partition
}

# --- New disks are always encrypted ------------------------------------------------------------

# Every stack already asks for encrypted disks; this makes it the account default, so a disk made
# by hand or by a launch template that forgets it is encrypted too (AWS-managed key, no cost).
resource "aws_ebs_encryption_by_default" "on" {
  enabled = true
}

# --- Audit log: CloudTrail of management events in every region --------------------------------

# Who did what, from where, kept past the console's 90 days. Management events only (no S3 data
# events): the first copy of them is free, the bucket costs cents a month.
resource "aws_s3_bucket" "audit" {
  bucket = "tickr-audit-${local.account}"
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.audit_log_keep_days
    }
  }
}

data "aws_iam_policy_document" "audit" {
  statement {
    sid       = "TlsOnly"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
  statement {
    sid       = "CloudTrailChecksAcl"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:cloudtrail:${var.region}:${local.account}:trail/tickr-audit"]
    }
  }
  statement {
    sid       = "CloudTrailWrites"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/AWSLogs/${local.account}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:cloudtrail:${var.region}:${local.account}:trail/tickr-audit"]
    }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit.json
}

resource "aws_cloudtrail" "audit" {
  name                          = "tickr-audit"
  s3_bucket_name                = aws_s3_bucket.audit.id
  is_multi_region_trail         = true
  include_global_service_events = true
  # Each hour's digest file proves no log file was changed or removed afterwards.
  enable_log_file_validation = true
  depends_on                 = [aws_s3_bucket_policy.audit]
}

# --- Threat detection: GuardDuty, findings mailed (off until the owner's yes) -------------------

resource "aws_guardduty_detector" "main" {
  count  = var.guardduty_enabled ? 1 : 0
  enable = true
}

resource "aws_sns_topic" "security" {
  count = var.guardduty_enabled ? 1 : 0
  name  = "tickr-security-findings"
}

data "aws_iam_policy_document" "security_topic" {
  count = var.guardduty_enabled ? 1 : 0
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security[0].arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.guardduty[0].arn]
    }
  }
}

resource "aws_sns_topic_policy" "security" {
  count  = var.guardduty_enabled ? 1 : 0
  arn    = aws_sns_topic.security[0].arn
  policy = data.aws_iam_policy_document.security_topic[0].json
}

resource "aws_sns_topic_subscription" "security_owner" {
  count     = var.guardduty_enabled ? 1 : 0
  topic_arn = aws_sns_topic.security[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_event_rule" "guardduty" {
  count       = var.guardduty_enabled ? 1 : 0
  name        = "tickr-guardduty-findings"
  description = "GuardDuty findings at or above guardduty_min_severity"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail        = { severity = [{ numeric = [">=", var.guardduty_min_severity] }] }
  })
}

resource "aws_cloudwatch_event_target" "guardduty" {
  count = var.guardduty_enabled ? 1 : 0
  rule  = aws_cloudwatch_event_rule.guardduty[0].name
  arn   = aws_sns_topic.security[0].arn
}
