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
