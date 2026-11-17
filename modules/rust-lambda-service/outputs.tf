output "lambda_function_url" {
  description = "The Function URL on the alias (what callers should use), or null when function_url is false. Before v0.18.0 this was the unqualified URL, now unqualified_function_url."
  value       = var.function_url ? aws_lambda_function_url.current[0].function_url : null
}

output "unqualified_function_url" {
  description = "The unqualified Function URL, which invokes $LATEST (the URL before v0.18.0), or null when function_url or unqualified_function_url is false."
  value       = var.function_url && var.unqualified_function_url ? aws_lambda_function_url.this[0].function_url : null
}

output "lambda_function_name" {
  description = "Lambda function name."
  value       = aws_lambda_function.this.function_name
}

output "lambda_function_arn" {
  description = "Lambda function ARN, unqualified: invoking it runs $LATEST. Invoke lambda_alias_arn instead."
  value       = aws_lambda_function.this.arn
}

output "lambda_invoke_arn" {
  description = "Lambda invoke ARN, unqualified: it runs $LATEST. Integrate lambda_alias_invoke_arn instead."
  value       = aws_lambda_function.this.invoke_arn
}

output "lambda_alias_name" {
  description = "The alias that serves (\"current\"): the qualifier for a Lambda permission on the alias."
  value       = aws_lambda_alias.current.name
}

output "lambda_alias_arn" {
  description = "The serving alias's ARN: the target for an EventBridge schedule or another invoker, with a permission whose qualifier is lambda_alias_name. lambda_function_arn invokes $LATEST."
  value       = aws_lambda_alias.current.arn
}

output "lambda_alias_invoke_arn" {
  description = "The serving alias's invoke ARN (for API Gateway integrations, with a permission whose qualifier is lambda_alias_name). lambda_invoke_arn invokes $LATEST."
  value       = aws_lambda_alias.current.invoke_arn
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
