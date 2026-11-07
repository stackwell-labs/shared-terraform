# The role's inline policy is the CloudWatch Logs grants for the function's log
# group plus the caller's statements. Mocked provider, so no AWS credentials.

mock_provider "aws" {}

run "policy_is_log_grants_then_caller_statements" {
  command = plan

  variables {
    app_name   = "svc"
    aws_region = "eu-west-1"
    extra_policy_statements = [
      { Action = ["s3:GetObject"], Effect = "Allow", Resource = "arn:aws:s3:::b/*" }
    ]
  }

  assert {
    condition     = aws_iam_role.lambda.name == "svc-lambda-role" && aws_iam_role_policy.lambda.name == "svc-lambda-policy"
    error_message = "role and policy names are the ones rust-lambda-service always used"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.lambda.policy).Statement[0].Resource == "arn:aws:logs:eu-west-1:*:log-group:/aws/lambda/svc:*"
    error_message = "the first statement grants writes to the function's own log group"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.lambda.policy).Statement[2].Action == ["s3:GetObject"]
    error_message = "the caller's statements follow the log grants"
  }
}
