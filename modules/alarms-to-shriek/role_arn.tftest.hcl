# Locks in shared-terraform#2: with role_arn this module creates no IAM and the
# target uses the given role; without it, the role is created here and the
# target uses that. Mocked provider so this needs no AWS credentials.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/svc-alarms-to-shriek" }
  }
}

run "without_role_arn_creates_the_role_here" {
  command = apply

  variables {
    name_prefix = "svc"
  }

  assert {
    condition     = length(module.role) == 1
    error_message = "without role_arn the module must create the forwarding role"
  }

  assert {
    condition     = aws_cloudwatch_event_target.shriek.role_arn == "arn:aws:iam::111122223333:role/svc-alarms-to-shriek"
    error_message = "the target must use the role the module created"
  }

  assert {
    condition     = output.role_arn == aws_cloudwatch_event_target.shriek.role_arn
    error_message = "output role_arn must be the role the target uses"
  }
}

run "with_role_arn_creates_no_iam" {
  command = plan

  variables {
    name_prefix = "svc"
    role_arn    = "arn:aws:iam::111122223333:role/made-elsewhere"
  }

  assert {
    condition     = length(module.role) == 0
    error_message = "with role_arn the module must create no IAM role or policy"
  }

  assert {
    condition     = aws_cloudwatch_event_target.shriek.role_arn == "arn:aws:iam::111122223333:role/made-elsewhere"
    error_message = "the target must use the given role_arn"
  }

  assert {
    condition     = output.role_arn == "arn:aws:iam::111122223333:role/made-elsewhere"
    error_message = "output role_arn must be the given role_arn"
  }
}

run "rejects_a_non_role_arn" {
  command = plan

  variables {
    name_prefix = "svc"
    role_arn    = "svc-alarms-to-shriek"
  }

  expect_failures = [var.role_arn]
}
