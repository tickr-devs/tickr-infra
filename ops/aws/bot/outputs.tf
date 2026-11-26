output "server_address" {
  description = "Elastic IP of the bot server: the A record of the bot's domain at Namecheap, and the address to bind a Webull key to."
  value       = aws_eip.bot.public_ip
}

output "instance_id" {
  description = "Server instance id, for `aws ssm start-session --target`."
  value       = aws_instance.bot.id
}

output "bot_secret" {
  description = "Secrets Manager secret the owner fills with the bot's credential variables (README)."
  value       = aws_secretsmanager_secret.bot_env.name
}

output "image_repository" {
  description = "Registry the server pulls the release image from (tag = commit)."
  value       = aws_ecr_repository.bot.repository_url
}

output "image_push_role" {
  description = "Role the image workflow assumes; set it as the repository variable AWS_IMAGE_PUSH_ROLE (README)."
  value       = aws_iam_role.image_push.arn
}
