# Forward every CloudWatch alarm state change in THIS account to Shriek.
#
# CloudWatch publishes an "Alarm State Change" event to the account's default
# EventBridge bus for every alarm, whatever its alarm_actions say. Routing on
# that event rather than on each alarm's SNS topic means:
#   * an alarm added later pages without anyone remembering to wire it;
#   * existing SNS/email actions are untouched (this is additive);
#   * the producer holds no credential: authority is the forwarding role plus
#     Shriek's bus policy naming this account.
#
# Only ALARM and OK are forwarded. Shriek opens a Critical incident (a phone
# push) on ALARM and resolves it on OK; INSUFFICIENT_DATA carries no verdict.
#
# var.exclude_alarm_names drops alarms by name, for an account that also holds
# alarms nobody should be woken for (the 081 data vault's test-plane tables).
# The filter runs here, at the source, so an excluded alarm never leaves the
# account and Shriek needs no knowledge of it.

data "aws_caller_identity" "current" {}

resource "aws_cloudwatch_event_rule" "alarms" {
  name        = "${var.name_prefix}-alarms-to-shriek"
  description = "Forward CloudWatch alarm ALARM/OK transitions to Shriek (phone paging)."
  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    account       = [data.aws_caller_identity.current.account_id]
    detail = merge(
      { state = { value = ["ALARM", "OK"] } },
      # Only present when exclusions are set, so an instance without them keeps
      # exactly the v0.9.0 pattern (and a version bump plans no change).
      length(var.exclude_alarm_names) == 0 ? {} : {
        alarmName = [{ "anything-but" = { wildcard = var.exclude_alarm_names } }]
      },
    )
  })
  tags = var.tags
}

# EventBridge requires a role on every cross-account event-bus target. Without
# var.role_arn this instance creates it (the alarms-to-shriek-role module);
# with it, this instance creates no IAM at all, so its applier needs no IAM
# write (shared-terraform#2).
module "role" {
  count  = var.role_arn == null ? 1 : 0
  source = "../alarms-to-shriek-role"

  name_prefix          = var.name_prefix
  shriek_event_bus_arn = var.shriek_event_bus_arn
  tags                 = var.tags
}

# Up to v0.10.0 the role lived here; these keep a ref bump a no-op.
moved {
  from = aws_iam_role.forward
  to   = module.role[0].aws_iam_role.forward
}

moved {
  from = aws_iam_role_policy.forward
  to   = module.role[0].aws_iam_role_policy.forward
}

locals {
  role_arn = var.role_arn == null ? module.role[0].role_arn : var.role_arn
}

resource "aws_cloudwatch_event_target" "shriek" {
  rule      = aws_cloudwatch_event_rule.alarms.name
  target_id = "shriek"
  arn       = var.shriek_event_bus_arn
  role_arn  = local.role_arn
}
