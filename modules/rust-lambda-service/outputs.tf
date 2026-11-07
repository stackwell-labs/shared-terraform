output "lambda_function_url" {
  description = "Direct Lambda Function URL."
  value       = aws_lambda_function_url.this.function_url
}

output "lambda_function_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.this.function_name
}

output "lambda_function_arn" {
  description = "Lambda function ARN."
  value       = aws_lambda_function.this.arn
}

output "lambda_invoke_arn" {
  description = "Lambda invoke ARN (for API Gateway integrations)."
  value       = aws_lambda_function.this.invoke_arn
}

output "lambda_role_arn" {
  description = "Execution role ARN: role_arn when given, else the role this module created."
  value       = local.role_arn
}

output "lambda_role_name" {
  description = "Execution role name: derived from role_arn when given, else the role this module created."
  value       = local.role_name
}

output "log_group_name" {
  description = "CloudWatch log group name."
  value       = aws_cloudwatch_log_group.lambda.name
}

output "config_secret_arn" {
  description = "The config secret's ARN (created or given), or null without config_secret. Pass it to another function's config_secret.arn to share the secret."
  value       = local.config_secret_arn
}

output "config_secret_read_statement" {
  description = "The IAM statement granting secretsmanager:GetSecretValue on the config secret, or null without config_secret. The module adds it to the role it creates; with role_arn, put it on that role where it is managed."
  value       = var.config_secret == null ? null : local.config_secret_read_statements[0]
}
