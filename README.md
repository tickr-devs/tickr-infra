# tickr-infra

Terraform of the Tickr servers in AWS (account 407384449055, us-east-1), split out of
tickr-devs/Tickr on 2026-11-27 with its history:

| Folder | What |
|---|---|
| `ops/aws/bot` | the bot server (api.tickr.bot), its data disk, the release image registry and the GitHub OIDC role tickr-bot pushes images with |
| `ops/aws/web` | the tickr.bot web server, its bucket and SES |
| `ops/aws/account` | account-wide settings |

The training stack (`ops/aws/training`) stays in tickr-bot next to the research code it runs.
Each folder's README says how to apply it. Applying is always the owner's step on his Mac; CI only
checks formatting, `terraform validate` and that each server's uid matches its image's user.
