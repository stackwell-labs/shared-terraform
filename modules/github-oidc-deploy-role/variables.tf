variable "repo" {
  description = "GitHub repository in owner/name form, e.g. stackwell-labs/granite. Only this repo's chosen branch can assume the role."
  type        = string
}

variable "branch" {
  description = "Git branch allowed to assume the role."
  type        = string
  default     = "main"
}

variable "role_name" {
  description = "Name of the deploy role."
  type        = string
  default     = "github-actions-deploy"
}

variable "role_description" {
  description = "Description for the deploy role."
  type        = string
  default     = null
}

variable "policy_json" {
  description = "The scoped inline deploy policy (JSON string) attached to the role. This is the per-service least-privilege policy; the module owns only the OIDC trust, not what the role may do."
  type        = string
}

variable "max_session_duration" {
  description = "Maximum assumed-role session duration in seconds."
  type        = number
  default     = 3600
}

variable "create_oidc_provider" {
  description = "Whether to create the GitHub Actions OIDC provider. Set false in accounts where the provider already exists (an account holds at most one provider per URL); pass its ARN via oidc_provider_arn instead."
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "ARN of an existing GitHub Actions OIDC provider. Required when create_oidc_provider is false."
  type        = string
  default     = null
}

variable "thumbprint_list" {
  description = "GitHub Actions OIDC root CA thumbprints. The default is the canonical pair (single source of truth) — only override to pin a different set."
  type        = list(string)
  default = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

variable "trust_self_manage" {
  description = "Whether to grant the role iam:UpdateAssumeRolePolicy on itself, so a role that applies its own root can keep its trust up to date. Set false when someone other than the role applies it (e.g. an admin-applied root): there the grant only lets CI change who may assume the role."
  type        = bool
  default     = true
}
