variable "name_prefix" {
  description = "Prefix for the rule and role names (usually the service's app_name). One instance per ACCOUNT: the rule forwards every alarm in the account, so a second instance would page twice."
  type        = string
}

variable "shriek_event_bus_arn" {
  description = "The event bus Shriek ingests alarm state changes from. Shriek's account must list this account in its alarm_source_accounts, or the bus policy refuses the PutEvents."
  type        = string
  default     = "arn:aws:events:us-east-1:653135933102:event-bus/default"
}

variable "tags" {
  description = "Tags applied to the rule and role."
  type        = map(string)
  default     = {}
}
