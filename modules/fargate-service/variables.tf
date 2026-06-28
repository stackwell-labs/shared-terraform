variable "name_prefix" {
  type        = string
  description = "Prefix for all resource names (the service name)."
}

variable "region" {
  type        = string
  description = "AWS region (for the awslogs driver config)."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR for the service VPC. /16; public = .0/.1, private = .10/.11."
}

variable "domain_name" {
  type        = string
  description = "FQDN the service is served at. A child hosted zone is created and delegated from the parent."
}

variable "parent_zone_id" {
  type        = string
  description = "Route53 zone id of the parent zone (in the aws.parent_dns account) to write the NS delegation into."
}

variable "container_name" {
  type        = string
  description = "Container name (also the awslogs stream prefix and the ALB load_balancer container_name)."
}

variable "container_port" {
  type        = number
  description = "Container/app port (ALB target + service SG ingress)."
  default     = 8080
}

variable "image_tag" {
  type        = string
  description = "Image tag in the created ECR repo."
  default     = "latest"
}

variable "environment" {
  type        = list(object({ name = string, value = string }))
  description = "Plain environment variables for the container."
  default     = []
}

variable "secrets" {
  type        = list(object({ name = string, valueFrom = string }))
  description = "Secrets Manager-injected env (valueFrom = secret ARN, optionally with :jsonkey::)."
  default     = []
}

variable "secret_arns" {
  type        = list(string)
  description = "Secret ARNs the task execution role may GetSecretValue. Empty = no secret-read policy."
  default     = []
}

variable "secret_read_policy_name" {
  type        = string
  description = "Inline policy name for the exec role's secret-read grant (override to preserve an existing name on adoption)."
  default     = "secret-read"
}

variable "task_cpu" {
  type        = number
  description = "Fargate task CPU units (256 = 0.25 vCPU)."
  default     = 256
}

variable "task_memory" {
  type        = number
  description = "Fargate task memory (MB)."
  default     = 512
}

variable "cpu_architecture" {
  type        = string
  description = "X86_64 or ARM64 (must match the image build host)."
  default     = "X86_64"
}

variable "desired_count" {
  type        = number
  description = "Fargate task count."
  default     = 1
}

variable "health_check_path" {
  type        = string
  description = "ALB target-group health-check path."
  default     = "/health"
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log retention."
  default     = 30
}

variable "task_volumes" {
  type = list(object({
    name               = string
    efs_file_system_id = string
    root_directory     = optional(string, "/")
    transit_encryption = optional(string, "ENABLED")
  }))
  description = "Optional task-level volumes (e.g. EFS). Empty for stateless/DB-backed services."
  default     = []
}

variable "mount_points" {
  type = list(object({
    sourceVolume  = string
    containerPath = string
    readOnly      = bool
  }))
  description = "Optional container mount points (paired with task_volumes)."
  default     = []
}
