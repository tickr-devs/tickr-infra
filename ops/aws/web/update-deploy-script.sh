#!/bin/sh
# Install the current tickr-web-deploy (from user-data.sh) on the running web server, from the Mac:
#   ops/aws/web/update-deploy-script.sh
# Terraform ignores user-data changes on an existing server, so a change to the deploy script in
# user-data.sh reaches the server only through this. Touches nothing else on the machine.
# Needs: aws CLI signed in (profile from AWS_PROFILE) and this folder's terraform state.
set -eu
export AWS_PAGER=""
here=$(cd "$(dirname "$0")" && pwd)
# The script between the DEPLOY markers; Terraform renders $$ as $, and the script has no
# other template variables.
script=$(sed -n "/^cat > \/usr\/local\/bin\/tickr-web-deploy <<'DEPLOY'\$/,/^DEPLOY\$/p" "$here/user-data.sh" |
  sed '1d;$d' | sed 's/\$\$/$/g')
if [ -z "$script" ]; then
  echo "No tickr-web-deploy script found in user-data.sh." >&2
  exit 1
fi
encoded=$(printf '%s\n' "$script" | base64 | tr -d '\n')
instance=$(terraform -chdir="$here" output -raw instance_id)
command_id=$(aws ssm send-command --instance-ids "$instance" \
  --document-name AWS-RunShellScript \
  --comment "tickr-web-deploy update" \
  --parameters "commands=[\"echo $encoded | base64 -d > /usr/local/bin/tickr-web-deploy.new && bash -n /usr/local/bin/tickr-web-deploy.new && chmod 755 /usr/local/bin/tickr-web-deploy.new && mv /usr/local/bin/tickr-web-deploy.new /usr/local/bin/tickr-web-deploy && echo installed\"]" \
  --query Command.CommandId --output text)
# The CLI's own waiter gives up after its fixed number of checks and fails on any error (expired
# sign-in, missing permission); the result below is printed either way.
aws ssm wait command-executed --command-id "$command_id" --instance-id "$instance" || true
aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance" \
  --query '[Status, StandardOutputContent, StandardErrorContent]' --output text
