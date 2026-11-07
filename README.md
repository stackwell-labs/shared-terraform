# agent-platform--tf-modules

Shared Terraform modules for the agent-platform services. Single source of
truth for the infrastructure stacks that were previously copy-pasted across
loom, model-gateway, granite, drive, pigeon, and bowerbird.

## Modules

### `rust-lambda-service`

The Lambda + IAM execution role + log group + public Function URL stack, plus
the AccessDeniedException CloudFormation workaround (a public Function URL
needs the `InvokedViaFunctionUrl` permission condition, which
`aws_lambda_permission` cannot express, so a tiny CloudFormation stack manages
it).

Service-specific resources (DynamoDB tables, S3 buckets, KMS keys, SNS topics,
API Gateway, CloudFront) stay in each service's own config and are wired into
the Lambda through `env` and `extra_policy_statements`.

```hcl
module "service" {
  source = "git::https://github.com/stackwell-labs/shared-terraform.git//modules/rust-lambda-service?ref=v0.1.0"

  app_name               = var.app_name
  service                = "loom"
  zip_path               = var.lambda_zip_path
  aws_region             = var.aws_region
  lambda_timeout_seconds = 60

  env = {
    RUST_LOG = "loom_service=info"
    # ...service env...
  }

  # Service-specific IAM beyond the base CloudWatch Logs grants:
  extra_policy_statements = [
    {
      Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
      Effect   = "Allow"
      Resource = aws_dynamodb_table.records.arn
    }
  ]
}
```

Outputs: `lambda_function_url`, `lambda_function_name`, `lambda_function_arn`,
`lambda_invoke_arn`, `lambda_role_arn`, `lambda_role_name`, `log_group_name`.

### `github-oidc-deploy-role`

The GitHub Actions OIDC provider + a scoped deploy role assumable only by one
repo's branch via web identity. Single source of truth for the OIDC thumbprint
list. The role's *permissions* are the caller's responsibility (pass
`policy_json`); the module owns only the trust relationship.

```hcl
module "ci_deploy" {
  source = "git::https://github.com/stackwell-labs/shared-terraform.git//modules/github-oidc-deploy-role?ref=v0.1.0"

  repo        = "stackwell-labs/granite"
  policy_json = data.aws_iam_policy_document.deploy_scoped.json
}
```

In an account that already has the GitHub OIDC provider, set
`create_oidc_provider = false` and pass `oidc_provider_arn`.

The module grants the role `iam:UpdateAssumeRolePolicy` on itself, so a role
that applies its own root can keep its trust up to date. When someone else
applies the role (an admin-applied root), set `trust_self_manage = false`:
there the grant would only let CI change who may assume the role. A `moved`
block makes a bump from v0.5.0 on the default plan no change.

Outputs: `role_arn`, `role_name`, `oidc_provider_arn`.

### `alarms-to-shriek`

Routes every CloudWatch alarm in an account to Shriek, which pages a phone:
an EventBridge rule on the default bus matches `CloudWatch Alarm State Change`
(ALARM and OK only) and forwards it to Shriek's bus through a role that can
only `events:PutEvents` there. Shriek opens a Critical incident on ALARM and
resolves it on OK.

```mermaid
flowchart LR
  A[CloudWatch alarm] -->|state change event| B[default bus, product acct]
  B -->|rule + role| C[default bus, shriek acct 653135933102]
  C -->|rule| D[shriek-service-tick]
  D -->|Critical incident| E[FCM push]
```

Existing SNS/email actions are left alone, and alarms added later are covered
without any change here.

```hcl
module "alarms_to_shriek" {
  source      = "git::https://github.com/stackwell-labs/shared-terraform.git//modules/alarms-to-shriek?ref=v0.9.0"
  name_prefix = var.app_name
  tags        = local.common_tags
}
```

To keep some alarms off the phone, pass EventBridge wildcard patterns of alarm
names to leave out. They are dropped at the source, so they never reach Shriek:

```hcl
  exclude_alarm_names = ["t_*_test_*"] # the 081 vault's test-plane tables
```

Without it, the rule's pattern is exactly v0.9.0's, so bumping the ref plans
no change. The provider constraint is `>= 5.0, < 7.0`, so roots on AWS provider
5.x and 6.x can both use it.

Use it **once per account**, because the rule forwards every alarm in the
account. The account must also be listed in Shriek's `alarm_source_accounts`
(`stackwell-labs/shriek`, `service/infra/aws/variables.tf`). Shriek's bus policy
refuses accounts that are not listed, and the map gives each account its board
row name.

A CI deploy role applying this needs `events:{PutRule,DescribeRule,DeleteRule,
PutTargets,RemoveTargets,ListTargetsByRule,TagResource,UntagResource,
ListTagsForResource}` on the rule, and `iam:{CreateRole,GetRole,DeleteRole,
TagRole,UntagRole,PutRolePolicy,GetRolePolicy,DeleteRolePolicy,
ListRolePolicies,ListAttachedRolePolicies,ListInstanceProfilesForRole,PassRole}`
on the `<name_prefix>-alarms-to-shriek` role.

That IAM write lets whatever applies the root rewrite the role's trust and
policy. To keep it out of a CI-applied root, make the role in a root that an
admin applies, with the role-only module `alarms-to-shriek-role`, and pass its
ARN in. The module then creates no IAM, and the CI role needs only
`iam:PassRole` on the role (plus the `events:*` above):

```hcl
# admin-applied root
module "alarms_to_shriek_role" {
  source      = "git::https://github.com/stackwell-labs/shared-terraform.git//modules/alarms-to-shriek-role?ref=v0.11.0"
  name_prefix = var.app_name
}

# CI-applied root
module "alarms_to_shriek" {
  source      = "git::https://github.com/stackwell-labs/shared-terraform.git//modules/alarms-to-shriek?ref=v0.11.0"
  name_prefix = var.app_name
  role_arn    = "arn:aws:iam::<account>:role/<app_name>-alarms-to-shriek"
}
```

`role_arn` must be known at plan time (a literal or a remote-state output),
because it decides whether the role is created. Without it, the module calls
`alarms-to-shriek-role` itself, so the role's trust and permission live in one
place either way, and `moved` blocks make a bump from v0.9.0/v0.10.0 plan no
change.

To hand an existing instance's role to another root, move it before setting
`role_arn`, or the CI root plans to destroy it: import it into the admin root
(`module.alarms_to_shriek_role.aws_iam_role.forward`, ID
`<app_name>-alarms-to-shriek`, and `...aws_iam_role_policy.forward`, ID
`<app_name>-alarms-to-shriek:put-events-on-shriek-bus`), then
`terraform state rm module.alarms_to_shriek.module.role` in the CI root.

Outputs: `rule_arn`, `role_arn` (the role the target uses, given or created).
`alarms-to-shriek-role` outputs `role_arn`, `role_name`.

## Versioning

Tagged releases (`vMAJOR.MINOR.PATCH`). Consumers pin via `?ref=vX.Y.Z`.
