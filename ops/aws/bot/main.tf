# The owner's bot server (docs/backlog.md T15; plan https://claude.ai/artifact/QhzoePqMNyeqFeYwUga59C).
# One always-on machine in the default VPC: the bot, the API behind HTTPS, and their data disk.
# Isolated from the training stack: its role reads only the bot's own secret, the research user's
# rules cover only machines tagged tickr:role=training, and the training machines cannot read
# this secret. No SSH: sessions go through SSM, and the only open port is 443.
#
# Applying this stack starts a paid machine: only after the owner's yes on a named sum.

data "aws_caller_identity" "me" {}

data "aws_partition" "current" {}

locals {
  account   = data.aws_caller_identity.me.account_id
  partition = data.aws_partition.current.partition
  role_tag  = "bot"
  subnet_id = coalesce(var.subnet_id, sort(data.aws_subnets.default.ids)[0])
  runtime_files = ["tickr-secrets", "tickr-secrets.service", "tickr-heartbeat",
  "tickr-heartbeat.service", "tickr-heartbeat.timer", "Caddyfile", "caddy-tickr.conf"]
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "bot" {
  id = local.subnet_id
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# --- Secret ---------------------------------------------------------------------------------

# The bot's credential variables (Webull app key and secret, Telegram token and chat id, Massive
# key) as one JSON object {"NAME": "value"}. Created empty: the owner puts the value from his
# Mac (README); Terraform never holds it. Only the server role may read it.
resource "aws_secretsmanager_secret" "bot_env" {
  name        = "tickr-bot/env"
  description = "Tickr bot credential variables, JSON object of NAME to value; read only by the bot server role"
}

# Identity policies alone would let any account admin read the value too. This resource policy
# denies reading it to every principal but the server role. The owner still writes it
# (PutSecretValue) and can change this policy as account admin, which CloudTrail records.
data "aws_iam_policy_document" "bot_env" {
  statement {
    sid       = "OnlyTheServerReads"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = [aws_iam_role.bot.arn]
    }
  }
}

resource "aws_secretsmanager_secret_policy" "bot_env" {
  secret_arn = aws_secretsmanager_secret.bot_env.arn
  policy     = data.aws_iam_policy_document.bot_env.json
}

# --- Machine role ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bot" {
  name               = "tickr-bot-server"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# SSM agent: sessions and commands, no SSH key anywhere.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bot.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "bot" {
  statement {
    sid       = "ReadOwnSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.bot_env.arn]
  }
  # The managed SSM policy allows reading any parameter; the server needs none.
  statement {
    sid       = "NoParameters"
    effect    = "Deny"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["*"]
  }
  # The off-server heartbeat (a later change) writes one metric namespace only.
  statement {
    sid       = "Heartbeat"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Tickr/Bot"]
    }
  }
}

resource "aws_iam_role_policy" "bot" {
  name   = "bot-server"
  role   = aws_iam_role.bot.id
  policy = data.aws_iam_policy_document.bot.json
}

resource "aws_iam_instance_profile" "bot" {
  name = "tickr-bot-server"
  role = aws_iam_role.bot.name
}

# --- Network --------------------------------------------------------------------------------

resource "aws_security_group" "bot" {
  name        = "tickr-bot"
  description = "Bot server: HTTPS in only when expose_api is on, all out"
  vpc_id      = data.aws_vpc.default.id

  dynamic "ingress" {
    for_each = var.expose_api ? [443] : []
    content {
      description = "HTTPS to Caddy, also the Lets Encrypt TLS-ALPN challenge"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Fixed address: the domain's A record and the Webull key binding point at it.
resource "aws_eip" "bot" {
  domain = "vpc"
  tags = {
    Name = "tickr-bot"
  }
}

resource "aws_eip_association" "bot" {
  allocation_id = aws_eip.bot.id
  instance_id   = aws_instance.bot.id
}

# --- Disks and server -----------------------------------------------------------------------

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.bot.availability_zone
  size              = var.data_disk_gb
  type              = "gp3"
  encrypted         = true
  tags = {
    Name           = "tickr-bot-data"
    "tickr:role"   = local.role_tag
    "tickr:backup" = "nightly"
  }
  # The database lives here: an apply must never delete it.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "bot" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.bot.id]
  iam_instance_profile   = aws_iam_instance_profile.bot.name
  # A console click or a stray apply must not delete the bot server.
  disable_api_termination = true

  root_block_device {
    volume_size           = var.root_disk_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Burstable types (t3): "unlimited" keeps full CPU when the bot needs it (a throttled bot at the
  # open is worse than a few dollars); CPU above the baseline is billed, at most about $0.05 per
  # vCPU-hour, which the account budget mail covers. Ignored by non-burstable types.
  credit_specification {
    cpu_credits = "unlimited"
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = templatefile("${path.module}/user-data.sh", {
    data_volume_id  = aws_ebs_volume.data.id
    aws_cli_version = var.installers.aws_cli_version
    aws_cli_sha256  = var.installers.aws_cli_sha256
    bot_domain      = var.bot_domain
    region          = var.region
    service_uid     = var.service_uid
    # Runtime files (files/), passed as base64 so the template never interprets their text.
    files = { for name in local.runtime_files : name => filebase64("${path.module}/files/${name}") }
  })

  tags = {
    Name         = "tickr-bot"
    "tickr:role" = local.role_tag
  }

  # A new Ubuntu image or a changed first-boot script must not stop or replace the running bot
  # on the next apply. Both take effect only on a deliberate rebuild (README).
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.bot.id
  # Detaching under a running database risks it: stop the bot first, never force.
  stop_instance_before_detaching = true
}

# --- Nightly snapshots of the data disk -----------------------------------------------------

data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "tickr-bot-snapshots"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data" {
  description        = "Tickr bot data disk nightly"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags = {
      "tickr:backup" = "nightly"
    }

    schedule {
      name      = "nightly"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = [var.snapshot_time_utc]
      }

      retain_rule {
        count = var.snapshot_keep_days
      }
    }
  }
}

# --- Machine alarms -------------------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  name = "tickr-bot-alarms"
}

resource "aws_sns_topic_subscription" "owner" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# AWS host failure: move the server to healthy hardware (same id, address and disks), and mail.
resource "aws_cloudwatch_metric_alarm" "system_check" {
  alarm_name          = "tickr-bot-system-check"
  alarm_description   = "Bot server: AWS hardware check failed; the server is recovered onto new hardware"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = aws_instance.bot.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = ["arn:${local.partition}:automate:${var.region}:ec2:recover", aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# Operating system hung or out of memory: mail only. A reboot is a decision for the owner, since
# the bot may hold a position.
resource "aws_cloudwatch_metric_alarm" "instance_check" {
  alarm_name          = "tickr-bot-instance-check"
  alarm_description   = "Bot server: the operating system does not answer AWS's check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  dimensions          = { InstanceId = aws_instance.bot.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# --- Off-server heartbeat -------------------------------------------------------------------

# The server sends one point a minute while it and its local API answer (files/tickr-heartbeat).
# No point for 5 minutes = the server is down, hung or cut off: mail the owner. The bot's own
# watchdog runs on this server and cannot report that. Missing data counts as breaching, so a
# server that never started sending alarms too.
resource "aws_cloudwatch_metric_alarm" "heartbeat" {
  alarm_name          = "tickr-bot-heartbeat"
  alarm_description   = "Bot server: no heartbeat for 5 minutes (server or its API down, hung or cut off)"
  namespace           = "Tickr/Bot"
  metric_name         = "Heartbeat"
  statistic           = "SampleCount"
  period              = 60
  evaluation_periods  = var.heartbeat_missing_minutes
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}
