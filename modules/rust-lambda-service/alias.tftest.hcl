# Traffic goes through an alias on a published version, never $LATEST, so a
# cold start never runs the previous binary on the new env (shared-terraform#9).
# Mocked provider, so this needs no AWS credentials.

mock_provider "aws" {}

variables {
  app_name = "svc"
  # Any existing file: only its hash is read, and the provider is mocked.
  zip_path = "versions.tf"
}

run "every_apply_publishes_and_the_alias_serves_that_version" {
  command = plan

  assert {
    condition     = aws_lambda_function.this.publish == true
    error_message = "the function must publish a version holding both code and config"
  }

  assert {
    condition     = aws_lambda_alias.current.name == "current" && output.lambda_alias_name == "current"
    error_message = "the serving alias is named current"
  }
}

run "the_alias_points_at_the_published_version" {
  command = apply

  variables {
    # A real-shaped ARN: the mock's random strings fail the provider's ARN check.
    role_arn = "arn:aws:iam::123456789012:role/svc-lambda-role"
  }

  override_resource {
    target = aws_lambda_function.this
    values = {
      version = "7"
    }
  }

  assert {
    condition     = aws_lambda_alias.current.function_version == "7"
    error_message = "the alias must serve the version this apply published"
  }

  assert {
    condition     = output.lambda_alias_arn == aws_lambda_alias.current.arn && output.lambda_alias_invoke_arn == aws_lambda_alias.current.invoke_arn
    error_message = "the alias outputs must name the alias"
  }
}
