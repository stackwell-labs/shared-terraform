# rust-lambda-service
#
# The Lambda + IAM execution role + log group + public Function URL stack that
# loom, model-gateway, granite, drive, pigeon, and bowerbird all copy-pasted.
# Includes the AccessDeniedException CloudFormation workaround: the
# aws_lambda_permission resource cannot grant the InvokedViaFunctionUrl
# condition, so a tiny CloudFormation stack manages that permission instead.
#
# Service-specific resources (DynamoDB tables, S3 buckets, KMS keys, SNS
# topics, API Gateway, CloudFront) stay in each service's own config and are
# wired in through `env` and `extra_policy_statements` (or, with `role_arn`,
# through the policy of a role managed elsewhere).

locals {
  lambda_name    = var.app_name
  log_group_name = "/aws/lambda/${local.lambda_name}"

  common_tags = merge({
    Project = var.app_name
    Service = coalesce(var.service, var.app_name)
    Managed = "terraform"
  }, var.tags)
}

# The execution role, unless the caller passes one it manages elsewhere
# (role_arn). A root that must not hold IAM write calls lambda-execution-role
# itself and passes the ARN here (shared-terraform#1).
module "execution_role" {
  source = "../lambda-execution-role"
  count  = var.role_arn == null ? 1 : 0

  app_name                = var.app_name
  aws_region              = var.aws_region
  extra_policy_statements = var.extra_policy_statements
  tags                    = local.common_tags
}

# Before shared-terraform#1 the role and its policy were resources of this
# module. These keep a caller that passes no role_arn at no change.
moved {
  from = aws_iam_role.lambda
  to   = module.execution_role[0].aws_iam_role.lambda
}

moved {
  from = aws_iam_role_policy.lambda
  to   = module.execution_role[0].aws_iam_role_policy.lambda
}

locals {
  role_arn = var.role_arn != null ? var.role_arn : module.execution_role[0].role_arn
  # The last path segment of the ARN: arn:aws:iam::<acct>:role[/path]/<name>.
  role_name = var.role_arn != null ? regex("[^/]+$", var.role_arn) : module.execution_role[0].role_name
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

resource "aws_lambda_function" "this" {
  function_name                  = local.lambda_name
  role                           = local.role_arn
  runtime                        = "provided.al2023"
  handler                        = "bootstrap"
  architectures                  = ["x86_64"]
  filename                       = var.zip_path
  source_code_hash               = filebase64sha256(var.zip_path)
  memory_size                    = var.lambda_memory_size
  timeout                        = var.lambda_timeout_seconds
  reserved_concurrent_executions = var.lambda_reserved_concurrency

  environment {
    variables = var.env
  }

  depends_on = [aws_cloudwatch_log_group.lambda]

  tags = local.common_tags

  lifecycle {
    precondition {
      # With role_arn the module writes no policy, so the statements would be
      # dropped without a word. They belong where the role is managed.
      condition     = var.role_arn == null || length(var.extra_policy_statements) == 0
      error_message = "extra_policy_statements has no effect when role_arn is set: put them on the role where it is managed (e.g. its lambda-execution-role call)."
    }
  }
}

resource "aws_lambda_function_url" "this" {
  function_name      = aws_lambda_function.this.function_name
  authorization_type = "NONE"

  dynamic "cors" {
    for_each = var.function_url_cors == null ? [] : [var.function_url_cors]
    content {
      allow_origins  = cors.value.allow_origins
      allow_methods  = cors.value.allow_methods
      allow_headers  = cors.value.allow_headers
      expose_headers = cors.value.expose_headers
      max_age        = cors.value.max_age
    }
  }
}

resource "aws_lambda_permission" "function_url_public" {
  statement_id           = "AllowPublicFunctionUrlInvoke"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.this.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# AccessDeniedException workaround: aws_lambda_permission cannot express the
# InvokedViaFunctionUrl condition that AWS requires for public Function URL
# invocation, so a CloudFormation stack manages that one permission.
resource "aws_cloudformation_stack" "function_url_invoke_public" {
  name = "${var.app_name}-function-url-invoke-public"

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Resources = {
      FunctionUrlInvokePublic = {
        Type = "AWS::Lambda::Permission"
        Properties = {
          Action                = "lambda:InvokeFunction"
          FunctionName          = aws_lambda_function.this.function_name
          Principal             = "*"
          InvokedViaFunctionUrl = true
        }
      }
    }
  })

  depends_on = [aws_lambda_function_url.this]

  tags = local.common_tags
}
