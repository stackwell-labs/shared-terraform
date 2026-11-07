# lambda-execution-role
#
# The execution role a rust-lambda-service function runs as, and its inline
# policy: the CloudWatch Logs grants every such function needs plus the
# caller's own statements.
#
# rust-lambda-service calls this when it is given no role_arn. A root that
# keeps IAM out of CI's reach calls it directly instead and passes the role's
# ARN to the CI root's rust-lambda-service (shared-terraform#1, granite#26).
# Either way the base statements live only here.

locals {
  # rust-lambda-service names its function app_name, and Lambda logs to
  # /aws/lambda/<function name>.
  log_group_name = "/aws/lambda/${var.app_name}"

  base_log_statements = [
    {
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Effect   = "Allow"
      Resource = "arn:aws:logs:${var.aws_region}:*:log-group:${local.log_group_name}:*"
    },
    {
      Action   = ["logs:CreateLogGroup"]
      Effect   = "Allow"
      Resource = "arn:aws:logs:${var.aws_region}:*:log-group:*"
    }
  ]

  policy_statements = concat(local.base_log_statements, var.extra_policy_statements)
}

resource "aws_iam_role" "lambda" {
  name = "${var.app_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "lambda" {
  name = "${var.app_name}-lambda-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.policy_statements
  })
}
