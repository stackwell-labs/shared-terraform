# The role EventBridge assumes to forward alarm state changes to Shriek's bus.
#
# EventBridge requires a role on every cross-account event-bus target created
# after 2023-03-02. This one can do exactly one thing: put events on Shriek's
# bus, and only EventBridge in this account can assume it.
#
# alarms-to-shriek calls this module itself unless it is given a role_arn. A
# root whose applier must not hold IAM write (a CI-applied root,
# shared-terraform#2) calls this module from a separate, admin-applied root
# instead and passes the role's ARN to alarms-to-shriek. Either way the trust
# and the permission are defined only here.

data "aws_caller_identity" "current" {}

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
