variable "region" {
  description = "AWS region of the bot server (us-east-1, next to Webull's and Massive's US endpoints)."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "Bot server type, the one setting to grow the server. Owner 2026-11-25: start small (t3.medium = 2 vCPU, 4 GB, about $30 a month on-demand) and grow when needed, e.g. when the live model and the Massive feed are switched on (spec thread estimate: models 1-3 GB in memory, live features unmeasured). A change stops and starts the server on apply: only on a weekend while flat."
  type        = string
  default     = "t3.medium"
}

variable "subnet_id" {
  description = "Subnet of the server; null = the first default subnet (sorted by id). The data volume is created in the same zone, so changing it later means moving the data."
  type        = string
  default     = null
}

variable "root_disk_gb" {
  description = "Root disk in GB: system, Docker images and container logs."
  type        = number
  default     = 30
}

variable "data_disk_gb" {
  description = "Data disk in GB, mounted at /srv/tickr/data: the bot's data folder ([run] data_dir: SQLite database, archives, Webull token). Separate from the root disk so the server can be rebuilt without touching it."
  type        = number
  default     = 100
}

variable "snapshot_keep_days" {
  description = "Nightly snapshots of the data disk kept, in days (one snapshot a night)."
  type        = number
  default     = 7
}

variable "snapshot_time_utc" {
  description = "Time of the nightly data-disk snapshot, HH:MM UTC. DLM starts within an hour of it: 06:00 UTC = 01:00 or 02:00 New York, after the post-market session and clear of the 03:30 preflight."
  type        = string
  default     = "06:00"
}

variable "bot_domain" {
  description = "Name the apps reach the bot at over HTTPS (Caddy's certificate name). Its A record at Namecheap points at the server_address output; the API's remote_hosts_file must list it."
  type        = string
  default     = "bot.tickr.bot"
}

variable "heartbeat_missing_minutes" {
  description = "Minutes without a heartbeat point before the tickr-bot-heartbeat alarm mails the owner (one point a minute is sent)."
  type        = number
  default     = 5
}

variable "service_uid" {
  description = "uid and gid of the server's tickr account. Must equal TICKR_UID and TICKR_GID in .github/workflows/server-image.yml, which builds the image's user with them."
  type        = number
  default     = 1500
}

variable "github_repo" {
  description = "GitHub repository whose main-branch workflow may push the release image (OIDC trust of role tickr-image-push), exactly as the OIDC subject names it. The organisation uses immutable ids in the subject (owner@owner_id/name@repo_id), read from CloudTrail on 2026-11-26; the ids are public, not credentials."
  type        = string
  default     = "tickr-devs@357523297/Tickr@1458033118"
}

variable "images_kept" {
  description = "Release images kept in the registry; older ones expire. One per merged change that touches the image."
  type        = number
  default     = 60
}

variable "alert_email" {
  description = "Address the server alarms (machine checks failed, heartbeat missing) are mailed to. Personal data: pass it at apply time (-var or an untracked tfvars file), never commit it. AWS mails a confirmation link once."
  type        = string
}

variable "installers" {
  description = "Installers user-data.sh downloads and runs as root, each pinned to one version and refused unless its file has this sha256. aws_cli_version: AWS CLI v2 release (https://awscli.amazonaws.com/awscli-exe-linux-x86_64-<version>.zip); aws_cli_sha256: sha256 of that zip. Same values as the training stack; move both together."
  type = object({
    aws_cli_version = string
    aws_cli_sha256  = string
  })
  default = {
    aws_cli_version = "2.39.0"
    aws_cli_sha256  = "6c89ce7ed7bc0a2520e2bc3eeedfea4e2eb2e7da2836860c9471871408404036"
  }
  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.installers.aws_cli_sha256))
    error_message = "installers: aws_cli_sha256 must be 64 lowercase hex characters."
  }
}

variable "expose_api" {
  description = "Open port 443 to the internet so the apps reach the API through Caddy. Stays false until the API refuses repeated bad tokens per address, its error paths leak nothing (PR 794), and the owner has decided which commands may be reached from the internet."
  type        = bool
  default     = false
}

variable "releases_kept" {
  description = "Deployed releases (tag release-<commit>) kept in the registry for rollback and rebuilds; the oldest beyond this expire. Counts deploys, not merges."
  type        = number
  default     = 20
}
