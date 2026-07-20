# github-oidc-deploy-role
#
# The GitHub Actions OIDC provider + a scoped deploy role assumable only by one
# repo's branch via web identity (no static keys). This is the single source of
# truth for the OIDC thumbprint list (see variables.tf default).
#
# The role's *permissions* are the caller's responsibility — pass the scoped
# least-privilege policy as policy_json. The module owns only the trust
# relationship, so each service keeps its own narrow blast radius.

resource "aws_iam_openid_connect_provider" "github_actions" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.thumbprint_list
}

locals {
  provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github_actions[0].arn : var.oidc_provider_arn

  # GitHub emits the OIDC `sub` in one of two forms, and which one a repo gets is
  # outside our control: the plain `repo:org/name:...`, or — for repos on GitHub's
  # newer immutable-ID default (notably repos transferred between orgs) — the form
  # `repo:org@<org-id>/name@<repo-id>:...`. Accept BOTH so a repo keeps deploying when
  # GitHub flips it, which it is doing account-wide. (This was found the hard way:
  # a transferred repo's deploy 403'd on AssumeRoleWithWebIdentity because only the
  # plain form was trusted.)
  #
  # SAFE, not a blanket wildcard: `@*` wildcards ONLY the numeric id. The literal org
  # and name segments stay fixed, and a GitHub org name cannot contain `@`, so no
  # other org or repo can satisfy either pattern. `var.repo` must be plain `org/name`.
  repo_parts = split("/", var.repo)
  sub_patterns = [
    "repo:${var.repo}:ref:refs/heads/${var.branch}",
    "repo:${local.repo_parts[0]}@*/${local.repo_parts[1]}@*:ref:refs/heads/${var.branch}",
  ]
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      # StringLike with multiple values is an OR: the token's sub need match only one.
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.sub_patterns
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  description          = coalesce(var.role_description, "Assumed by GitHub Actions in ${var.repo}@${var.branch} to deploy.")
  max_session_duration = var.max_session_duration
}

resource "aws_iam_role_policy" "scoped" {
  name   = "${var.role_name}-scoped"
  role   = aws_iam_role.deploy.id
  policy = var.policy_json
}
