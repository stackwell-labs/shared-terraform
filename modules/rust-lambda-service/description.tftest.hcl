# The function's description is where a service records the commit it deploys
# (shared-terraform#8). Mocked provider, so this needs no AWS credentials.

mock_provider "aws" {}

variables {
  app_name = "svc"
  # Any existing file: only its hash is read, and the provider is mocked.
  zip_path = "versions.tf"
}

run "default_leaves_the_description_blank" {
  command = plan

  assert {
    condition     = aws_lambda_function.this.description == ""
    error_message = "without description the function's description must stay blank, so existing callers plan no change"
  }
}

run "description_is_set_on_the_function" {
  command = plan

  variables {
    description = "commit 0123456789abcdef0123456789abcdef01234567"
  }

  assert {
    condition     = aws_lambda_function.this.description == "commit 0123456789abcdef0123456789abcdef01234567"
    error_message = "description must be set on the function"
  }
}
