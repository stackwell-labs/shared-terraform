# The self-grant of iam:UpdateAssumeRolePolicy is on by default and is left out when
# trust_self_manage is false (shared-terraform#3). Mocked provider: no AWS credentials.

mock_provider "aws" {}

variables {
  repo        = "stackwell-labs/granite"
  policy_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
}

run "self_grant_on_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.trust_self_manage) == 1
    error_message = "by default the role must be able to update its own trust"
  }
}

run "self_grant_off_when_disabled" {
  command = plan

  variables {
    trust_self_manage = false
  }

  assert {
    condition     = length(aws_iam_role_policy.trust_self_manage) == 0
    error_message = "trust_self_manage = false must not create the self-grant"
  }

  assert {
    condition     = aws_iam_role_policy.scoped.name == "github-actions-deploy-scoped"
    error_message = "the scoped policy must still be attached"
  }
}
