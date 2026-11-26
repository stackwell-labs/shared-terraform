# Locks in that the trust accepts BOTH the plain OIDC subject and the immutable-ID
# form GitHub emits for transferred repos, each as one exact string. A repo that
# flips to immutable-IDs must keep deploying without a trust change, and no other
# repo may match either form: StringLike's `*` matches any text, so a wildcard in
# the immutable form let another repo's custom sub template through
# (shared-terraform#25). Mocked provider so this needs no AWS credentials.

mock_provider "aws" {}

variables {
  repo        = "stackwell-labs/bowerbird"
  owner_id    = 290129483
  repo_id     = 1318019917
  policy_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
}

run "trust_accepts_plain_and_immutable_subject_forms_exactly" {
  command = plan

  assert {
    condition = toset(output.trust_subject_patterns) == toset([
      "repo:stackwell-labs/bowerbird:ref:refs/heads/main",
      "repo:stackwell-labs@290129483/bowerbird@1318019917:ref:refs/heads/main",
    ])
    error_message = "trust must accept exactly the plain and the immutable-ID subject forms"
  }

  assert {
    condition     = alltrue([for p in output.trust_subject_patterns : !strcontains(p, "*") && !strcontains(p, "?")])
    error_message = "no sub value may hold a wildcard: in StringLike `*` matches any text, so another repo's sub could match"
  }

  assert {
    condition = anytrue([
      for c in data.aws_iam_policy_document.trust.statement[0].condition :
      c.variable == "token.actions.githubusercontent.com:sub" && c.test == "StringEquals"
    ])
    error_message = "the sub condition must be StringEquals, so no character in it is a wildcard"
  }
}

run "branch_is_pinned_in_both_forms" {
  command = plan

  variables {
    branch = "release"
  }

  assert {
    condition = toset(output.trust_subject_patterns) == toset([
      "repo:stackwell-labs/bowerbird:ref:refs/heads/release",
      "repo:stackwell-labs@290129483/bowerbird@1318019917:ref:refs/heads/release",
    ])
    error_message = "both forms must pin the chosen branch"
  }
}

run "fractional_repo_id_rejected" {
  command = plan

  variables {
    repo_id = 1.5
  }

  expect_failures = [var.repo_id]
}

run "zero_owner_id_rejected" {
  command = plan

  variables {
    owner_id = 0
  }

  expect_failures = [var.owner_id]
}

run "repo_without_owner_rejected" {
  command = plan

  variables {
    repo = "bowerbird"
  }

  expect_failures = [var.repo]
}
