output "audit_bucket" {
  description = "Bucket the CloudTrail audit log is written to (AWSLogs/<account>/CloudTrail/...)."
  value       = aws_s3_bucket.audit.id
}
