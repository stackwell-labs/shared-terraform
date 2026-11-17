# The public Function URL is on by default and can be turned off when another
# ingress (an API Gateway) fronts the function, so the function has no second
# public path past that ingress (pigeon#79). Since shared-terraform#9 the URL
# callers should use is on the alias; the unqualified one stays until a caller
# turns it off. Mocked provider, so this needs no
# AWS credentials.

mock_provider "aws" {}

variables {
  app_name = "svc"
  # Any existing file: only its hash is read, and the provider is mocked.
  zip_path = "versions.tf"
}

run "default_creates_the_function_url_and_its_permissions" {
  command = plan

  assert {
    condition = (
      length(aws_lambda_function_url.current) == 1 &&
      length(aws_lambda_permission.function_url_public_current) == 1 &&
      length(aws_cloudformation_stack.function_url_invoke_public_current) == 1 &&
      length(aws_lambda_function_url.this) == 1 &&
      length(aws_lambda_permission.function_url_public) == 1 &&
      length(aws_cloudformation_stack.function_url_invoke_public) == 1
    )
    error_message = "by default the module must create the alias's Function URL and the unqualified one, each with both public-invoke permissions"
  }

  assert {
    condition = (
      aws_lambda_function_url.current[0].qualifier == "current" &&
      aws_lambda_permission.function_url_public_current[0].qualifier == "current"
    )
    error_message = "the alias's Function URL and its permission must be qualified by the alias"
  }

  assert {
    condition = (
      aws_lambda_function_url.this[0].qualifier == null &&
      aws_lambda_permission.function_url_public[0].qualifier == null
    )
    error_message = "the unqualified Function URL must stay unqualified, so a bump keeps the URL callers already use"
  }
}

run "unqualified_function_url_false_keeps_only_the_alias_url" {
  command = plan

  variables {
    unqualified_function_url = false
  }

  assert {
    condition = (
      length(aws_lambda_function_url.current) == 1 &&
      length(aws_lambda_permission.function_url_public_current) == 1 &&
      length(aws_cloudformation_stack.function_url_invoke_public_current) == 1 &&
      length(aws_lambda_function_url.this) == 0 &&
      length(aws_lambda_permission.function_url_public) == 0 &&
      length(aws_cloudformation_stack.function_url_invoke_public) == 0
    )
    error_message = "with unqualified_function_url = false only the alias's Function URL and its permissions remain"
  }

  assert {
    condition     = output.unqualified_function_url == null
    error_message = "unqualified_function_url must be null without the unqualified Function URL"
  }
}

run "function_url_false_creates_none_of_them" {
  command = plan

  variables {
    function_url = false
  }

  assert {
    condition = (
      length(aws_lambda_function_url.current) == 0 &&
      length(aws_lambda_permission.function_url_public_current) == 0 &&
      length(aws_cloudformation_stack.function_url_invoke_public_current) == 0 &&
      length(aws_lambda_function_url.this) == 0 &&
      length(aws_lambda_permission.function_url_public) == 0 &&
      length(aws_cloudformation_stack.function_url_invoke_public) == 0
    )
    error_message = "with function_url = false the module must create no Function URL and no public-invoke permission"
  }

  assert {
    condition     = output.lambda_function_url == null && output.unqualified_function_url == null
    error_message = "lambda_function_url and unqualified_function_url must be null without a Function URL"
  }
}

run "cors_without_a_function_url_is_an_error" {
  command = plan

  variables {
    function_url = false
    function_url_cors = {
      allow_origins = ["https://example.com"]
      allow_methods = ["GET"]
      allow_headers = ["authorization"]
    }
  }

  expect_failures = [aws_lambda_function.this]
}
