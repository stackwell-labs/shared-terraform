# The two ways the execution role can be had (shared-terraform#1): created here
# (role_arn = null, the default and the only mode before), or passed in and
# managed elsewhere, so the root applying this module needs no IAM write.
# Mocked provider, so this needs no AWS credentials.

mock_provider "aws" {}

variables {
  app_name = "svc"
  # Any existing file: only its hash is read, and the provider is mocked.
  zip_path = "versions.tf"
}

run "default_creates_the_role" {
  command = plan

  assert {
    condition     = length(module.execution_role) == 1
    error_message = "with no role_arn the module must create the role"
  }

  assert {
    condition     = output.lambda_role_name == "svc-lambda-role"
    error_message = "the created role keeps its pre-#1 name"
  }
}

run "role_arn_creates_no_iam_and_the_function_uses_it" {
  command = plan

  variables {
    role_arn = "arn:aws:iam::123456789012:role/some/path/granite-lambda-role"
  }

  assert {
    condition     = length(module.execution_role) == 0
    error_message = "with role_arn the module must create no role or policy"
  }

  assert {
    condition     = aws_lambda_function.this.role == var.role_arn
    error_message = "the function must run as the given role"
  }

  assert {
    condition     = output.lambda_role_arn == var.role_arn
    error_message = "lambda_role_arn must be the given ARN"
  }

  assert {
    condition     = output.lambda_role_name == "granite-lambda-role"
    error_message = "lambda_role_name must be the ARN's last path segment"
  }
}

run "role_arn_with_extra_statements_is_an_error" {
  command = plan

  variables {
    role_arn = "arn:aws:iam::123456789012:role/granite-lambda-role"
    extra_policy_statements = [
      { Action = ["s3:GetObject"], Effect = "Allow", Resource = "*" }
    ]
  }

  expect_failures = [aws_lambda_function.this]
}

run "role_arn_must_be_a_role_arn" {
  command = plan

  variables {
    role_arn = "granite-lambda-role"
  }

  expect_failures = [var.role_arn]
}
