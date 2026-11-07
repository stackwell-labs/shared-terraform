# config_secret (shared-terraform#5): the service's adr-secret-storage secret,
# created as <service>/<plane>-config or given by ARN, granted to the role and
# named in the Lambda env. Mocked provider, so this needs no AWS credentials.

mock_provider "aws" {
  # One run applies, to see the created secret's ARN in the env and the policy.
  # The provider checks these are ARNs, which a mock's random string is not.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/drive-service-lambda-role" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:drive/live-config-AbCdEf" }
  }
}

variables {
  app_name = "drive-service"
  service  = "drive"
  # Any existing file: only its hash is read, and the provider is mocked.
  zip_path = "versions.tf"
  env      = { RUST_LOG = "info" }
}

run "no_secret_version_is_declared" {
  # Terraform owns the secret, never its value: a secret version, as a
  # resource or a data source, would put the value in state.
  command = plan

  module {
    source = "./tests/declared-resources"
  }

  variables {
    dirs = [".", "../lambda-execution-role"]
  }

  assert {
    condition     = contains(output.types, "resource aws_secretsmanager_secret")
    error_message = "the scan must see the module's own secret resource (else it scans nothing)"
  }

  assert {
    condition     = length([for t in output.types : t if strcontains(t, "aws_secretsmanager_secret_version")]) == 0
    error_message = "no aws_secretsmanager_secret_version, resource or data source, may be declared"
  }
}

run "default_wires_no_secret" {
  command = plan

  assert {
    condition     = length(aws_secretsmanager_secret.config) == 0
    error_message = "without config_secret no secret is created"
  }

  assert {
    condition     = output.config_secret_arn == null && output.config_secret_read_statement == null
    error_message = "without config_secret the outputs are null"
  }

  assert {
    condition     = aws_lambda_function.this.environment[0].variables == tomap({ RUST_LOG = "info" })
    error_message = "without config_secret env is passed through unchanged"
  }
}

run "plane_creates_the_derived_secret" {
  command = apply

  variables {
    config_secret = { env_var = "DRIVE_CONFIG_SECRET", plane = "live" }
  }

  assert {
    condition     = aws_secretsmanager_secret.config[0].name == "drive/live-config"
    error_message = "the secret is <service>/<plane>-config"
  }

  assert {
    condition     = output.config_secret_arn == aws_secretsmanager_secret.config[0].arn
    error_message = "config_secret_arn is the created secret's ARN"
  }

  assert {
    condition     = aws_lambda_function.this.environment[0].variables["DRIVE_CONFIG_SECRET"] == aws_secretsmanager_secret.config[0].arn
    error_message = "the env var carries the secret's ARN"
  }

  assert {
    condition     = aws_lambda_function.this.environment[0].variables["RUST_LOG"] == "info"
    error_message = "the caller's env is kept"
  }

  assert {
    condition = output.config_secret_read_statement == {
      Action   = ["secretsmanager:GetSecretValue"]
      Effect   = "Allow"
      Resource = aws_secretsmanager_secret.config[0].arn
    }
    error_message = "the read statement grants GetSecretValue on the secret alone"
  }

  assert {
    condition = contains(
      jsondecode(module.execution_role[0].policy_json).Statement,
      output.config_secret_read_statement
    )
    error_message = "the created role's policy carries the read statement"
  }
}

run "test_plane" {
  command = plan

  variables {
    config_secret = { env_var = "DRIVE_CONFIG_SECRET", plane = "test" }
  }

  assert {
    condition     = aws_secretsmanager_secret.config[0].name == "drive/test-config"
    error_message = "the test plane's secret is <service>/test-config"
  }
}

run "arn_adopts_an_existing_secret" {
  command = plan

  variables {
    config_secret = {
      env_var = "GRANITE_CONFIG_SECRET"
      arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:granite/live-config-AbCdEf"
    }
  }

  assert {
    condition     = length(aws_secretsmanager_secret.config) == 0
    error_message = "with arn the module creates no secret"
  }

  assert {
    condition     = aws_lambda_function.this.environment[0].variables["GRANITE_CONFIG_SECRET"] == var.config_secret.arn
    error_message = "the env var carries the given ARN"
  }

  assert {
    condition     = output.config_secret_read_statement.Resource == var.config_secret.arn
    error_message = "the grant is on the given ARN"
  }
}

run "arn_with_role_arn_grants_nothing_but_offers_the_statement" {
  command = plan

  variables {
    role_arn = "arn:aws:iam::123456789012:role/granite-lambda-role"
    config_secret = {
      env_var = "GRANITE_CONFIG_SECRET"
      arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:granite/live-config-AbCdEf"
    }
  }

  assert {
    condition     = length(module.execution_role) == 0
    error_message = "with role_arn the module still creates no IAM"
  }

  assert {
    condition     = output.config_secret_read_statement.Resource == var.config_secret.arn
    error_message = "the statement is offered for the role's own root"
  }
}

run "plane_without_service_is_an_error" {
  command = plan

  variables {
    service       = null
    config_secret = { env_var = "DRIVE_CONFIG_SECRET", plane = "live" }
  }

  expect_failures = [aws_secretsmanager_secret.config]
}

run "plane_and_arn_together_is_an_error" {
  command = plan

  variables {
    config_secret = {
      env_var = "DRIVE_CONFIG_SECRET"
      plane   = "live"
      arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:drive/live-config-AbCdEf"
    }
  }

  expect_failures = [var.config_secret]
}

run "neither_plane_nor_arn_is_an_error" {
  command = plan

  variables {
    config_secret = { env_var = "DRIVE_CONFIG_SECRET" }
  }

  expect_failures = [var.config_secret]
}

run "unknown_plane_is_an_error" {
  command = plan

  variables {
    config_secret = { env_var = "DRIVE_CONFIG_SECRET", plane = "prod" }
  }

  expect_failures = [var.config_secret]
}

run "arn_must_be_a_secret_arn" {
  command = plan

  variables {
    config_secret = { env_var = "DRIVE_CONFIG_SECRET", arn = "drive/live-config" }
  }

  expect_failures = [var.config_secret]
}

run "env_var_already_in_env_is_an_error" {
  command = plan

  variables {
    env           = { DRIVE_CONFIG_SECRET = "drive/live-config" }
    config_secret = { env_var = "DRIVE_CONFIG_SECRET", plane = "live" }
  }

  expect_failures = [aws_lambda_function.this]
}
