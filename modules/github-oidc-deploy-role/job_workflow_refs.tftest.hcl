# The optional job_workflow_ref pin (shared-terraform#7): absent by default, so
# existing callers keep the same trust; when set, the trust ANDs a StringLike on
# the claim with the unchanged sub condition. Mocked provider: no AWS credentials.
# The assertions read the policy document's arguments, which a mock keeps as given.

mock_provider "aws" {}

variables {
  repo        = "stackwell-labs/drive"
  policy_json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
}

run "no_workflow_pin_by_default" {
  command = plan

  assert {
    condition     = length(data.aws_iam_policy_document.trust.statement[0].condition) == 2
    error_message = "by default the trust must check only aud and sub"
  }
}

run "workflow_pin_added_when_set" {
  command = plan

  variables {
    job_workflow_refs = ["stackwell-labs/shared-terraform/.github/workflows/terraform-deploy.yml@refs/heads/main"]
  }

  assert {
    condition = anytrue([
      for c in data.aws_iam_policy_document.trust.statement[0].condition :
      c.variable == "token.actions.githubusercontent.com:job_workflow_ref"
      && c.test == "StringLike"
      && length(c.values) == 1
      && contains(c.values, "stackwell-labs/shared-terraform/.github/workflows/terraform-deploy.yml@refs/heads/main")
    ])
    error_message = "job_workflow_refs must add a StringLike condition on the job_workflow_ref claim"
  }

  assert {
    condition = anytrue([
      for c in data.aws_iam_policy_document.trust.statement[0].condition :
      c.variable == "token.actions.githubusercontent.com:sub"
      && contains(c.values, "repo:stackwell-labs/drive:ref:refs/heads/main")
    ])
    error_message = "the branch pin in sub must still hold alongside the workflow pin"
  }
}

run "workflow_pin_without_ref_rejected" {
  command = plan

  variables {
    job_workflow_refs = ["stackwell-labs/shared-terraform/.github/workflows/terraform-deploy.yml"]
  }

  expect_failures = [var.job_workflow_refs]
}
