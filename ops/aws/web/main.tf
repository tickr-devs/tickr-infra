# tickr.bot web server (web/, ops/aws/web/README.md): one small machine for the public site, the
# Django app and its Postgres, apart from the bot (owner decision 2026-11-25). A break-in through
# the website must not reach the broker keys: this stack shares no role, secret or network with
# the bot. No inbound SSH: the owner reaches the machine through SSM only.

data "aws_caller_identity" "me" {}

data "aws_partition" "current" {}

data "aws_vpc" "default" {
  default = true
}

# Ubuntu 24.04 LTS for ARM (Graviton), Canonical's own images.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
}

locals {
  account   = data.aws_caller_identity.me.account_id
  partition = data.aws_partition.current.partition
}

# --- Bucket: nightly database dumps (backups/) and releases the Mac uploads (releases/) --------

resource "aws_s3_bucket" "web" {
  bucket = "tickr-web-${local.account}"
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "web" {
  bucket = aws_s3_bucket.web.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "web" {
  bucket = aws_s3_bucket.web.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning: the machine may write but never delete, so even a broken-into machine that writes
# over a dump's key leaves the earlier version in place until the lifecycle rule expires it.
resource "aws_s3_bucket_versioning" "web" {
  bucket = aws_s3_bucket.web.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "web" {
  bucket     = aws_s3_bucket.web.id
  depends_on = [aws_s3_bucket_versioning.web]
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.keep_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.overwritten_keep_days
    }
    # An upload cut off mid-way (ship.sh or a backup) leaves invisible parts; drop them after a day.
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
  rule {
    id     = "clean-delete-markers"
    status = "Enabled"
    filter {}
    expiration {
      expired_object_delete_marker = true
    }
  }
}

data "aws_iam_policy_document" "web_bucket" {
  statement {
    sid       = "TlsOnly"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.web.arn, "${aws_s3_bucket.web.arn}/*"]
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
}

resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = data.aws_iam_policy_document.web_bucket.json
}

# --- Email: SES sends from the domain; DKIM records go into Namecheap DNS (outputs) ------------

# Never send again to an address that bounced or complained (account-wide, all identities).
# Stated in the SES production-access request, so it must stay on.
resource "aws_sesv2_account_suppression_attributes" "web" {
  suppressed_reasons = ["BOUNCE", "COMPLAINT"]
}

resource "aws_sesv2_email_identity" "domain" {
  email_identity = var.domain
}

# --- Machine role: SSM sessions, its own bucket prefixes, mail from the domain only ------------

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "web" {
  name               = "tickr-web"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.web.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "web" {
  statement {
    sid       = "WriteBackups"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.web.arn}/backups/*"]
  }
  statement {
    sid       = "ReadReleases"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/releases/*"]
  }
  # SES checks every identity a message touches: the sender's, and while the account is in the
  # SES sandbox also each (verified) recipient's. So the grant covers all identities of the
  # account, and the condition keeps it to mail from the domain.
  statement {
    sid       = "SendMailFromTheDomain"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["arn:${local.partition}:ses:${var.region}:${local.account}:identity/*"]
    condition {
      test     = "StringLike"
      variable = "ses:FromAddress"
      values   = ["*@${var.domain}"]
    }
  }
  # django-ses reads the account's send rate before each message to stay under it (read only).
  statement {
    sid       = "ReadSendRate"
    actions   = ["ses:GetAccount"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "web" {
  name   = "tickr-web"
  role   = aws_iam_role.web.id
  policy = data.aws_iam_policy_document.web.json
}

resource "aws_iam_instance_profile" "web" {
  name = "tickr-web"
  role = aws_iam_role.web.name
}

# --- Network: only HTTP and HTTPS in (HTTP only redirects); no SSH ----------------------------

resource "aws_security_group" "web" {
  name        = "tickr-web"
  description = "tickr.bot web: HTTP and HTTPS from anywhere, nothing else"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "web" {
  for_each = {
    http4  = { port = 80, proto = "tcp", cidr = "0.0.0.0/0", cidr6 = null }
    https4 = { port = 443, proto = "tcp", cidr = "0.0.0.0/0", cidr6 = null }
    quic4  = { port = 443, proto = "udp", cidr = "0.0.0.0/0", cidr6 = null }
    http6  = { port = 80, proto = "tcp", cidr = null, cidr6 = "::/0" }
    https6 = { port = 443, proto = "tcp", cidr = null, cidr6 = "::/0" }
    quic6  = { port = 443, proto = "udp", cidr = null, cidr6 = "::/0" }
  }
  security_group_id = aws_security_group.web.id
  ip_protocol       = each.value.proto
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
  cidr_ipv6         = each.value.cidr6
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.web.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- The machine -------------------------------------------------------------------------------

resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  iam_instance_profile   = aws_iam_instance_profile.web.name
  vpc_security_group_ids = [aws_security_group.web.id]
  user_data = templatefile("${path.module}/user-data.sh", {
    domain          = var.domain
    bucket          = aws_s3_bucket.web.id
    region          = var.region
    service_uid     = var.service_uid
    aws_cli_version = var.installers.aws_cli_version
    aws_cli_sha256  = var.installers.aws_cli_sha256
  })
  user_data_replace_on_change = false
  # The database lives on this machine's disk: a destroy or a console terminate is refused until
  # this is set to false on purpose (ops/aws/web/README.md, "Removing the server").
  disable_api_termination = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.disk_gb
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
    # 2 hops: the app container reaches the instance role for SES through Docker's bridge.
    http_put_response_hop_limit = 2
  }

  # Replacing the machine would lose the database between backups: never on an AMI update.
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = {
    Name = "tickr-web"
  }
}

resource "aws_eip" "web" {
  instance = aws_instance.web.id
  domain   = "vpc"
}
