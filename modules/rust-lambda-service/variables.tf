variable "app_name" {
  description = "Resource name prefix. The Lambda function, IAM role (unless role_arn is set), log group, and CloudFormation workaround stack are all named from this."
  type        = string
}

variable "service" {
  description = "Logical service name, used only for the Service resource tag (e.g. \"loom\", \"granite\"). Defaults to app_name."
  type        = string
  default     = null
}

variable "zip_path" {
  description = "Path to the Lambda deployment zip (provided.al2023 bootstrap)."
  type        = string
}

variable "env" {
  description = "Environment variables injected into the Lambda. Pass the fully-resolved map; the caller is responsible for any conditional/merge logic."
  type        = map(string)
  default     = {}
}

variable "aws_region" {
  description = "AWS region. Used to scope the CloudWatch Logs IAM statements."
  type        = string
  default     = "us-east-1"
}

variable "role_arn" {
  description = "ARN of an existing execution role for the function. Null (the default) makes the module create <app_name>-lambda-role and its policy (via lambda-execution-role). When set, the module creates no IAM at all, so the root applying it needs no IAM write; extra_policy_statements must then be empty. Must be known at plan time (a literal, a variable, or another root's output), since it decides whether the role is created."
  type        = string
  default     = null

  validation {
    condition     = var.role_arn == null || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/([^/]+/)*[^/]+$", var.role_arn))
    error_message = "role_arn must be an IAM role ARN, arn:aws:iam::<12-digit account>:role/<name>."
  }
}

variable "extra_policy_statements" {
  description = "Additional IAM policy statements merged into the Lambda execution role's inline policy (e.g. DynamoDB, S3, KMS access). Each element is a statement object as it would appear in an IAM policy document's Statement array. Only with role_arn = null; with role_arn they belong on that role."
  type        = list(any)
  default     = []
}

variable "lambda_memory_size" {
  description = "Lambda memory size in MB."
  type        = number
  default     = 256
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout in seconds."
  type        = number
  default     = 30
}

variable "lambda_reserved_concurrency" {
  description = "Reserved concurrent executions. -1 (the Lambda default) means unreserved."
  type        = number
  default     = -1
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days for the Lambda log group."
  type        = number
  default     = 14
}

variable "function_url_cors" {
  description = "Optional CORS configuration for the Lambda Function URL. Null disables CORS (the default). When set, all four fields are required."
  type = object({
    allow_origins  = list(string)
    allow_methods  = list(string)
    allow_headers  = list(string)
    expose_headers = optional(list(string), [])
    max_age        = optional(number, 300)
  })
  default = null
}

variable "tags" {
  description = "Extra tags merged onto every resource this module creates."
  type        = map(string)
  default     = {}
}
