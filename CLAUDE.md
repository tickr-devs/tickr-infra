# tickr-infra: rules for agents

Terraform of the Tickr servers (bot, web, account settings). Split out of tickr-devs/Tickr on
2026-11-27. Siblings: `tickr-bot` (bot, API, model; builds the bot image), `tickr-web` (web app;
`web/deploy/ship.sh` reads this repo's `ops/aws/web` outputs), `tickr-ios` (Apple apps).

## Hard rules

1. **Applying is the owner's.** Agents never run `terraform apply`, `destroy` or `import` and never
   start a paid machine; every change that costs money states the monthly sum and waits for his yes.
2. **Secrets are never read, printed, logged or committed.** No tfstate, tfvars, keys or personal
   data (alert_email) in the repo. Never print the process environment (`env`, `printenv`,
   `set -x` in a shell that sees a secret).
3. **Every number has a description.** Every variable says what it is, its unit and who reads it.
4. **One source per value across repos.** The uids must equal the image users of tickr-bot
   (`server-image.yml` TICKR_UID/GID) and tickr-web (`web/Dockerfile` USER); CI job `server-uids`
   checks both against their main branches. The OIDC trust (`github_repo` in `ops/aws/bot`) names
   tickr-bot in the immutable owner@id/name@id form.
5. **Never weaken protections** (prevent_destroy, termination protection, deletion policies) to
   make a plan pass.

## How we work

- Work on a branch, open a pull request, keep it small. Threads never merge their own PRs; the
  Reviewer thread reviews and queues them. Changes to the bot server, its access or the OIDC role
  also need Fable at the exact head.
- Releases: Actions > release after each apply (semver tag), so the tag says what runs in AWS.
- Write code, comments, commits and docs in English. The owner reads Russian in chat.
