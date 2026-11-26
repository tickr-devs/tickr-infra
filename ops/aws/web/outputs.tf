output "instance_id" {
  description = "For SSM sessions and ship.sh."
  value       = aws_instance.web.id
}

output "bucket" {
  description = "Backups and releases."
  value       = aws_s3_bucket.web.id
}

output "dns_records_for_namecheap" {
  description = "Add these in Namecheap > Domain List > tickr.bot > Advanced DNS."
  value = concat(
    [
      { type = "A", host = "@", value = aws_eip.web.public_ip },
      { type = "A", host = "www", value = aws_eip.web.public_ip },
      { type = "TXT", host = "_dmarc", value = "v=DMARC1; p=quarantine; adkim=s; aspf=r" },
    ],
    [
      for token in aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens : {
        type  = "CNAME"
        host  = "${token}._domainkey"
        value = "${token}.dkim.amazonses.com"
      }
    ],
  )
}
