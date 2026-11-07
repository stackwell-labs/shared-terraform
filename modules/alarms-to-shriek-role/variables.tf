variable "name_prefix" {
  description = "Prefix for the role name, `<name_prefix>-alarms-to-shriek`. Use the same prefix as the account's alarms-to-shriek instance."
  type        = string
}

variable "shriek_event_bus_arn" {
  description = "The event bus the role may put events on. Must match the alarms-to-shriek instance's shriek_event_bus_arn."
  type        = string
  default     = "arn:aws:events:us-east-1:653135933102:event-bus/default"
}

variable "tags" {
  description = "Tags applied to the role."
  type        = map(string)
  default     = {}
}
