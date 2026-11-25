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
  description = "Days the bucket keeps each nightly database dump and each uploaded release."
  type        = number
  default     = 30
}
