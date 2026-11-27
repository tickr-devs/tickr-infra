variable "region" {
  description = "Home region of the account (us-east-1): the audit-log bucket and GuardDuty live here."
  type        = string
  default     = "us-east-1"
}

variable "audit_log_keep_days" {
  description = "Days the CloudTrail audit log keeps each log file before S3 deletes it. 365 = one year of who-did-what, past the console's free 90-day event history."
  type        = number
  default     = 365
}

variable "guardduty_enabled" {
  description = "Turn on GuardDuty threat detection (stolen keys used from odd places, crypto-mining, scans) with findings mailed to alert_email. Paid by volume of account events and traffic, a few USD a month for this account: stays false until the owner says yes on that sum."
  type        = bool
  default     = false
}

variable "guardduty_min_severity" {
  description = "Lowest GuardDuty finding severity that is mailed (GuardDuty scale 1-8.9: 4 = medium, 7 = high)."
  type        = number
  default     = 4
}

variable "alert_email" {
  description = "Address GuardDuty findings are mailed to; needed only with guardduty_enabled. Personal data: pass it at apply time (-var or an untracked tfvars file), never commit it. AWS mails a confirmation link once."
  type        = string
  default     = ""
  validation {
    condition     = !var.guardduty_enabled || var.alert_email != ""
    error_message = "alert_email: set it when guardduty_enabled is true, or the findings go nowhere."
  }
}
