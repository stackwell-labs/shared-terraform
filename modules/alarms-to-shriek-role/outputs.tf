output "role_arn" {
  description = "ARN of the forwarding role: pass it as alarms-to-shriek's role_arn."
  value       = aws_iam_role.forward.arn
}

output "role_name" {
  description = "Name of the forwarding role."
  value       = aws_iam_role.forward.name
}
