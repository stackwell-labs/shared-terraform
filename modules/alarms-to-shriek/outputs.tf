output "rule_arn" {
  description = "ARN of the forwarding rule (grant it in a CI deploy role's events:* statement)."
  value       = aws_cloudwatch_event_rule.alarms.arn
}

output "role_arn" {
  description = "ARN of the forwarding role the target uses: var.role_arn if set, else the one this instance created (the CI deploy role needs iam:PassRole on it either way)."
  value       = local.role_arn
}
