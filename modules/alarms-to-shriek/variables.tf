variable "name_prefix" {
  description = "Prefix for the rule and (without role_arn) role names (usually the service's app_name). One instance per ACCOUNT: the rule forwards every alarm in the account, so a second instance would page twice."
  type        = string
}

variable "shriek_event_bus_arn" {
  description = "The event bus Shriek ingests alarm state changes from. Shriek's account must list this account in its alarm_source_accounts, or the bus policy refuses the PutEvents."
  type        = string
  default     = "arn:aws:events:us-east-1:653135933102:event-bus/default"
}

variable "exclude_alarm_names" {
  description = "EventBridge wildcard patterns (`*` matches any run of characters) for alarm names that must NOT be forwarded, e.g. [\"t_*_test_*\"]. Empty (the default) forwards every alarm in the account."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for p in var.exclude_alarm_names : length(p) > 0 && p != "*"])
    error_message = "exclude_alarm_names entries must be non-empty, and \"*\" would exclude every alarm: drop the module instead."
  }
}

variable "role_arn" {
  description = "An existing forwarding role for the target, made by the alarms-to-shriek-role module in an admin-applied root. Set, this instance creates no IAM role or policy, so its applier needs only iam:PassRole on the role. Null (the default) creates the role here, as before. Must be known at plan time (a literal or another root's output), since it decides whether the role is created."
  type        = string
  default     = null

  validation {
    condition     = var.role_arn == null || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$", var.role_arn))
    error_message = "role_arn must be an IAM role ARN (arn:aws:iam::<account>:role/<name>), or null to create the role here."
  }
}

variable "tags" {
  description = "Tags applied to the rule, and to the role when this instance creates it."
  type        = map(string)
  default     = {}
}
