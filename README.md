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

## Reviewer approvals

Pull requests are opened under the owner's account, and GitHub never counts an author's own
approval. The Reviewer's verdict therefore becomes a real approval by a GitHub App with its own
identity, `tickr-reviewer`. When the owner's account (in practice the Reviewer thread) comments a
line `/approve <40-hex head sha>` on an open pull request, each repository's `approve` workflow
calls `.github/workflows/reviewer-approve.yml` here, which checks that the sha is still the head and
has the App approve exactly that commit. With "Dismiss stale approvals" on, any later push drops it.

The App has Contents and Pull requests write on the four repositories (contents write is what makes
GitHub count its approval); the workflow never checks out or runs pull request code. Its id is the
organization variable `TICKR_REVIEWER_APP_ID`, its private key the organization secret
`TICKR_REVIEWER_KEY`; both are set by the owner in GitHub settings, never in a file or a chat.
The org setting "Allow GitHub Actions to create and approve pull requests" stays off: it is not used.
