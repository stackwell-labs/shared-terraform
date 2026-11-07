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
# through the policy of a role managed elsewhere). The one exception is the
# service's adr-secret-storage config secret (`config_secret`), which every
# service needs in the same shape (shared-terraform#5).

locals {
  lambda_name    = var.app_name
  log_group_name = "/aws/lambda/${local.lambda_name}"

  common_tags = merge({
    Project = var.app_name
    Service = coalesce(var.service, var.app_name)
    Managed = "terraform"
  }, var.tags)
}

# The config secret (protocols docs/adr-secret-storage.md): created here when
# config_secret names a plane, else the given ARN. Terraform owns the secret,
# never its value: this module declares no aws_secretsmanager_secret_version
# (config_secret.tftest.hcl checks), so no value lands in state.
resource "aws_secretsmanager_secret" "config" {
  # Keyed on plane, which a caller writes as a literal, not on arn, which may
  # be another function's output and so unknown at plan time.
  count = try(var.config_secret.plane, null) != null ? 1 : 0

  name        = "${coalesce(var.service, "-")}/${var.config_secret.plane}-config"
  description = "${coalesce(var.service, "-")} ${var.config_secret.plane} config (adr-secret-storage). Values are written out of band, never by Terraform."

  tags = local.common_tags

  lifecycle {
    precondition {
      # app_name names a function, not the service ("drive-service-trash-sweep"
      # vs "drive"), and a secret's name is costly to change.
      condition     = var.service != null
      error_message = "config_secret.plane derives the secret name <service>/<plane>-config, so service must be set."
    }
  }
}

locals {
  config_secret_arn = (
    var.config_secret == null ? null :
    var.config_secret.plane != null ? aws_secretsmanager_secret.config[0].arn :
    var.config_secret.arn
  )

  config_secret_read_statements = var.config_secret == null ? [] : [{
    Action   = ["secretsmanager:GetSecretValue"]
    Effect   = "Allow"
    Resource = local.config_secret_arn
  }]

  config_secret_env = var.config_secret == null ? {} : {
    (var.config_secret.env_var) = local.config_secret_arn
  }
}

# The execution role, unless the caller passes one it manages elsewhere
# (role_arn). A root that must not hold IAM write calls lambda-execution-role
# itself and passes the ARN here (shared-terraform#1).
module "execution_role" {
  source = "../lambda-execution-role"
  count  = var.role_arn == null ? 1 : 0

  app_name                = var.app_name
  aws_region              = var.aws_region
  extra_policy_statements = concat(var.extra_policy_statements, local.config_secret_read_statements)
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
    variables = merge(var.env, local.config_secret_env)
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

    precondition {
      # CORS configures the Function URL, so without one it would do nothing.
      condition     = var.function_url || var.function_url_cors == null
      error_message = "function_url_cors has no effect when function_url is false: there is no Function URL to configure."
    }

    precondition {
      condition     = var.config_secret == null ? true : !contains(keys(var.env), var.config_secret.env_var)
      error_message = "env already sets config_secret.env_var; the module sets it to the config secret's ARN, so drop it from env."
    }
  }
}

# The public Function URL and its two public-invoke permissions, unless the
# caller turns them off (function_url = false) because another ingress, such as
# an API Gateway, fronts the function. Off, the function has no second public
# path that bypasses that ingress's throttle.
resource "aws_lambda_function_url" "this" {
  count = var.function_url ? 1 : 0

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
  count = var.function_url ? 1 : 0

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
  count = var.function_url ? 1 : 0

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

# Before function_url these three were single resources. These keep a caller
# that leaves function_url on at no change.
moved {
  from = aws_lambda_function_url.this
  to   = aws_lambda_function_url.this[0]
}

moved {
  from = aws_lambda_permission.function_url_public
  to   = aws_lambda_permission.function_url_public[0]
}

moved {
  from = aws_cloudformation_stack.function_url_invoke_public
  to   = aws_cloudformation_stack.function_url_invoke_public[0]
}
