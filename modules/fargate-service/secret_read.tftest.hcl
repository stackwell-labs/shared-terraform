# secret_read (shared-terraform#27): the exec role's secret-read policy exists
# only when secret_arns names a secret. With the default [] its statement would
# have no Resource, which IAM refuses, so the policy must not be written at all.
# Mocked providers, so this needs no AWS credentials.

mock_provider "aws" {
  # local.azs slices the first two names; a mock's empty list can't be sliced.
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["us-east-1a", "us-east-1b"] }
  }
  # A mocked policy document's json is a random string, which the IAM
  # resources refuse as not JSON. The secret-read statement itself is checked
  # on the document's arguments, which the mock leaves as configured.
  override_data {
    target = data.aws_iam_policy_document.ecs_assume
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_iam_policy_document.secret_read
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
}

mock_provider "aws" {
  alias = "parent_dns"
}

variables {
  name_prefix    = "svc"
  region         = "us-east-1"
  vpc_cidr       = "10.42.0.0/16"
  domain_name    = "svc.example.com"
  parent_zone_id = ""
  container_name = "svc"
}

run "default_writes_no_secret_read_policy" {
  command = plan

  # Only the policy and what it depends on: the rest of the stack is not under
  # test, and cert_validation's for_each needs ACM values a mock has only at
  # apply.
  plan_options {
    target = [aws_iam_role_policy.secret_read]
  }

  assert {
    condition     = length(aws_iam_role_policy.secret_read) == 0
    error_message = "with secret_arns = [] (the default) no secret-read policy is written"
  }
}

run "secret_arns_grant_get_secret_value_on_them_alone" {
  command = plan

  # Only the policy and what it depends on: the rest of the stack is not under
  # test, and cert_validation's for_each needs ACM values a mock has only at
  # apply.
  plan_options {
    target = [aws_iam_role_policy.secret_read]
  }

  variables {
    secret_arns = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:svc/live-config-AbCdEf"]
  }

  assert {
    condition     = length(aws_iam_role_policy.secret_read) == 1
    error_message = "with secret_arns the secret-read policy is written"
  }

  assert {
    condition     = data.aws_iam_policy_document.secret_read.statement[0].resources == toset(var.secret_arns)
    error_message = "the policy grants GetSecretValue on the given secrets alone"
  }
}
