# The public Function URL is on by default and can be turned off when another
# ingress (an API Gateway) fronts the function, so the function has no second
# public path past that ingress (pigeon#79). Mocked provider, so this needs no
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
      length(aws_lambda_function_url.this) == 1 &&
      length(aws_lambda_permission.function_url_public) == 1 &&
      length(aws_cloudformation_stack.function_url_invoke_public) == 1
    )
    error_message = "by default the module must create the Function URL and both public-invoke permissions"
  }
}

run "function_url_false_creates_none_of_them" {
  command = plan

  variables {
    function_url = false
  }

  assert {
    condition = (
      length(aws_lambda_function_url.this) == 0 &&
      length(aws_lambda_permission.function_url_public) == 0 &&
      length(aws_cloudformation_stack.function_url_invoke_public) == 0
    )
    error_message = "with function_url = false the module must create no Function URL and no public-invoke permission"
  }

  assert {
    condition     = output.lambda_function_url == null
    error_message = "lambda_function_url must be null without a Function URL"
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
