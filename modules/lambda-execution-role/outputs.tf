output "role_arn" {
  description = "Execution role ARN. Pass it to rust-lambda-service's role_arn."
  value       = aws_iam_role.lambda.arn
}

output "role_name" {
  description = "Execution role name."
  value       = aws_iam_role.lambda.name
}

output "policy_json" {
  description = "The role's inline policy document, as JSON."
  value       = aws_iam_role_policy.lambda.policy
}
