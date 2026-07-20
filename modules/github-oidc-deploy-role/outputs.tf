output "role_arn" {
  description = "ARN of the GitHub Actions deploy role."
  value       = aws_iam_role.deploy.arn
}

output "role_name" {
  description = "Name of the GitHub Actions deploy role."
  value       = aws_iam_role.deploy.name
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider (created or pre-existing)."
  value       = local.provider_arn
}

output "trust_subject_patterns" {
  description = "The GitHub OIDC `sub` patterns this role's trust accepts: the plain `repo:org/name:...` and the immutable-ID `repo:org@*/name@*:...` form (see main.tf). Exposed for verification and for callers that assert on the trust surface."
  value       = local.sub_patterns
}
