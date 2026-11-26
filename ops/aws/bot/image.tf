# Release image: built by CI from a commit on main (.github/workflows/server-image.yml), tagged
# with that commit, pushed here, pulled by the server. Tags are immutable, so a tag always means
# the code of its commit, which the bot also records (TICKR_CODE_VERSION).

resource "aws_ecr_repository" "bot" {
  name                 = "tickr-bot"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "bot" {
  repository = aws_ecr_repository.bot.name
  policy = jsonencode({
    # An image matched by a rule is never expired by a lower-priority one, so deployed releases
    # (tag release-<commit>, added by tickr-image-pull) only ever count against releases_kept.
    rules = [{
      rulePriority = 1
      description  = "deployed releases: keep the newest"
      selection = {
        tagStatus      = "tagged"
        tagPatternList = ["release-*"]
        countType      = "imageCountMoreThan"
        countNumber    = var.releases_kept
      }
      action = { type = "expire" }
      }, {
      rulePriority = 2
      description  = "other images: keep the newest"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.images_kept
      }
      action = { type = "expire" }
    }]
  })
}

# GitHub Actions signs in with a short-lived OIDC token: no AWS key is stored in GitHub.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # Required by the provider; AWS checks GitHub's certificate against its own trusted CAs and no
  # longer uses these for this host. GitHub's two published intermediate thumbprints.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

data "aws_iam_policy_document" "image_push_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only a workflow run on main of this one repository; never a pull request or a fork.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "image_push" {
  name                 = "tickr-image-push"
  assume_role_policy   = data.aws_iam_policy_document.image_push_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "image_push" {
  statement {
    sid       = "Login"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PushBotImage"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.bot.arn]
  }
}

resource "aws_iam_role_policy" "image_push" {
  name   = "push-bot-image"
  role   = aws_iam_role.image_push.id
  policy = data.aws_iam_policy_document.image_push.json
}

# The server pulls the image and may add any new tag to content already in the registry (PutImage;
# ECR has no condition key for the tag): tickr-image-pull marks a release with it. It cannot upload
# layers or delete an image, and tags are immutable, so no existing tag can be moved.
data "aws_iam_policy_document" "bot_pull" {
  statement {
    sid       = "Login"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "PullBotImage"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability", "ecr:DescribeImages"]
    resources = [aws_ecr_repository.bot.arn]
  }
  statement {
    sid       = "MarkRelease"
    actions   = ["ecr:PutImage"]
    resources = [aws_ecr_repository.bot.arn]
  }
}

resource "aws_iam_role_policy" "bot_pull" {
  name   = "pull-bot-image"
  role   = aws_iam_role.bot.id
  policy = data.aws_iam_policy_document.bot_pull.json
}
