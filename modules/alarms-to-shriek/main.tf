# Forward every CloudWatch alarm state change in THIS account to Shriek.
#
# CloudWatch publishes an "Alarm State Change" event to the account's default
# EventBridge bus for every alarm, whatever its alarm_actions say. Routing on
# that event rather than on each alarm's SNS topic means:
#   * an alarm added later pages without anyone remembering to wire it;
#   * existing SNS/email actions are untouched (this is additive);
#   * the producer holds no credential: authority is the IAM role below plus
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

# EventBridge requires a role on every cross-account event-bus target created
# after 2023-03-02. It can do exactly one thing: put events on Shriek's bus.
resource "aws_iam_role" "forward" {
  name = "${var.name_prefix}-alarms-to-shriek"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "forward" {
  name = "put-events-on-shriek-bus"
  role = aws_iam_role.forward.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = var.shriek_event_bus_arn
    }]
  })
}

resource "aws_cloudwatch_event_target" "shriek" {
  rule      = aws_cloudwatch_event_rule.alarms.name
  target_id = "shriek"
  arn       = var.shriek_event_bus_arn
  role_arn  = aws_iam_role.forward.arn
}
