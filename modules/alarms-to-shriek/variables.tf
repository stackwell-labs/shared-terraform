variable "name_prefix" {
  description = "Prefix for the rule and role names (usually the service's app_name). One instance per ACCOUNT: the rule forwards every alarm in the account, so a second instance would page twice."
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

variable "tags" {
  description = "Tags applied to the rule and role."
  type        = map(string)
  default     = {}
}
