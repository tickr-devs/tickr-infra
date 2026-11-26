variable "region" {
  description = "AWS region of the web server, its bucket and SES (us-east-1, like the rest of the account)."
  type        = string
  default     = "us-east-1"
}

variable "domain" {
  description = "Public domain the site is served at; DNS stays at Namecheap."
  type        = string
  default     = "tickr.bot"
}

variable "instance_type" {
  description = "Web server size: t4g.small = 2 Graviton vCPU, 2 GB, about 12.30 USD a month on demand."
  type        = string
  default     = "t4g.small"
}

variable "disk_gb" {
  description = "Encrypted gp3 system disk in GB (Docker images, Postgres, Caddy certificates); 0.08 USD per GB-month."
  type        = number
  default     = 20
}

variable "keep_days" {
  description = "Days the bucket keeps each nightly database dump and each uploaded release. A dump is gone for good at most keep_days + overwritten_keep_days after it was written."
  type        = number
  default     = 30
}

variable "overwritten_keep_days" {
  description = "Days an overwritten or expired object (an older S3 version) is kept before deletion: the window to notice and undo a dump overwritten from a broken-into machine."
  type        = number
  default     = 7
}

variable "service_uid" {
  description = "uid and gid of the server's tickrweb account, which owns the app's secret files (mode 600). Must equal the USER uid in web/Dockerfile (web/tests/test_deploy.py checks it)."
  type        = number
  default     = 10001
}

variable "installers" {
  description = "Installers user-data.sh downloads and runs as root, each pinned to one version and refused unless its file has this sha256. aws_cli_version: AWS CLI v2 release (https://awscli.amazonaws.com/awscli-exe-linux-aarch64-<version>.zip, Graviton build); aws_cli_sha256: sha256 of that zip. Same version as the bot and training stacks."
  type = object({
    aws_cli_version = string
    aws_cli_sha256  = string
  })
  default = {
    aws_cli_version = "2.39.0"
    aws_cli_sha256  = "05da9395b4d148c42e959192650bf4a7cbb59ea275fa334d0936c593c27b946f"
  }
  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.installers.aws_cli_sha256))
    error_message = "installers: aws_cli_sha256 must be 64 lowercase hex characters."
  }
}

variable "alert_email" {
  description = "Address the web server alarms (machine checks, site down, backup missing) are mailed to. Personal data: pass it at apply time (-var or an untracked tfvars file), never commit it. AWS mails a confirmation link once."
  type        = string
}

variable "site_check_interval_seconds" {
  description = "Seconds between Route 53 health checks of https://<domain>/ from each checker region: 30 (standard, 0.50 USD a month for an AWS endpoint) or 10 (fast, costs more)."
  type        = number
  default     = 30
}

variable "site_check_failures" {
  description = "Failed checks in a row before one Route 53 checker counts the site as down (Route 53 failure_threshold)."
  type        = number
  default     = 3
}

variable "site_down_minutes" {
  description = "Minutes the health check must report the site down before the tickr-web-site-down alarm mails the owner."
  type        = number
  default     = 5
}

variable "backup_missing_hours" {
  description = "Hours without an uploaded database dump before the tickr-web-backup-missing alarm mails the owner. The dump runs nightly (web/deploy/systemd/tickr-web-backup.timer): 26 = one missed night plus two hours of slack."
  type        = number
  default     = 26
}
