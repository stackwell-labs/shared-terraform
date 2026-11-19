# Locks in shriek#82: the rule forwards ALARM/OK state changes and alarm
# deletions, and exclude_alarm_names drops an excluded alarm from both.
# Mocked provider so this needs no AWS credentials; the pattern itself was
# checked against AWS's matcher (`aws events test-event-pattern`) when written.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333" }
  }
}

run "forwards_state_changes_and_deletions" {
  command = plan

  variables {
    name_prefix = "svc"
  }

  assert {
    condition = jsondecode(aws_cloudwatch_event_rule.alarms.event_pattern) == {
      source  = ["aws.cloudwatch"]
      account = ["111122223333"]
      "$or" = [
        {
          "detail-type" = ["CloudWatch Alarm State Change"]
          detail        = { state = { value = ["ALARM", "OK"] } }
        },
        {
          "detail-type" = ["CloudWatch Alarm Configuration Change"]
          detail        = { operation = ["delete"] }
        },
      ]
    }
    error_message = "the rule must forward ALARM/OK state changes and deletions, nothing else"
  }
}

run "exclusions_apply_to_both" {
  command = plan

  variables {
    name_prefix         = "svc"
    exclude_alarm_names = ["t_*_test_*"]
  }

  assert {
    condition = alltrue([
      for branch in jsondecode(aws_cloudwatch_event_rule.alarms.event_pattern)["$or"] :
      branch.detail.alarmName == [{ "anything-but" = { wildcard = ["t_*_test_*"] } }]
    ])
    error_message = "an excluded alarm's state changes and deletions must both stay in the account"
  }
}
