variable "app_name" {
  description = "The Lambda function's name (rust-lambda-service's app_name). The role is <app_name>-lambda-role, its policy <app_name>-lambda-policy, and the logs grant is scoped to /aws/lambda/<app_name>."
  type        = string
}

variable "aws_region" {
  description = "AWS region. Used to scope the CloudWatch Logs IAM statements."
  type        = string
  default     = "us-east-1"
}

variable "extra_policy_statements" {
  description = "Additional IAM policy statements merged into the role's inline policy (e.g. DynamoDB, S3, KMS access). Each element is a statement object as it would appear in an IAM policy document's Statement array."
  type        = list(any)
  default     = []
}

variable "tags" {
  description = "Tags for the role."
  type        = map(string)
  default     = {}
}
