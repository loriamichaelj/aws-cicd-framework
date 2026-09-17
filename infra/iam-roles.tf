locals {
  trusted_subjects = {
    for env in var.environments : env => [
      for repo in var.consumer_repos :
      "repo:${var.github_owner}/${repo}:environment:${env}"
    ]
  }
}

data "aws_iam_policy_document" "assume_role" {
  for_each = toset(var.environments)

  statement {
    sid     = "GitHubActionsOIDCScopedToEnvironment"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_issuer}:sub"
      values   = local.trusted_subjects[each.key]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each = toset(var.environments)

  name                 = "${var.role_name_prefix}-${each.key}"
  description          = "GitHub Actions OIDC deploy role scoped to the ${each.key} environment."
  assume_role_policy   = data.aws_iam_policy_document.assume_role[each.key].json
  max_session_duration = var.max_session_duration

  tags = {
    Environment = each.key
  }
}
