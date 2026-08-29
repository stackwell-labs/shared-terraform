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
  description = <<-EOT
    Route53 zone id of the parent zone (in the aws.parent_dns account) to write
    the NS delegation into. EMPTY ("") means this module does not manage the
    delegation at all — the record is expected to exist already, maintained out
    of band, which is what every non-Fargate service on this platform already
    does with parent-zone records.

    Why the escape hatch exists: the delegation is the ONLY resource here that
    lives in another AWS account, so it alone decides whether a consumer can run
    terraform from CI. Keeping it forces the consumer's CI role to hold
    write access to the parent zone — for amber-git, the zone that also carries
    socialgraph, jot and docs — to manage one NS record that is written once and
    then never changes. Empty lets a consumer trade that standing authority for
    an out-of-band record.

    Existing callers pass a real zone id and are unaffected: the delegation is
    created exactly as before.

    Deliberately has NO default: omitting it must be a plan-time error, not a
    silently undelegated domain.
  EOT
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
  description = <<-EOT
    Image tag in the created ECR repo. Used ONLY when image_digest is empty.

    A tag is a mutable name: the task definition resolves it at every fresh task
    launch, so what is running is decided by WHEN a task happened to start rather
    than by what anyone deployed. Prefer image_digest.
  EOT
  default     = "latest"
}

variable "image_digest" {
  type        = string
  description = <<-EOT
    Immutable image digest ("sha256:<64 hex>"). When set, the task definition
    references the content-addressed image and image_tag is ignored.

    This is what makes a deployment a RECORDED DECISION rather than a name
    lookup. With a mutable tag there is a window -- push succeeds, the ECS update
    fails -- in which the tag points at code no deploy ever verified, and the
    next crash restart silently adopts it. A digest cannot be reassigned, so that
    state stops being representable.

    Empty keeps the historical tag behaviour, so adopting this is opt-in per
    consumer.
  EOT
  default     = ""

  validation {
    # Catch a malformed digest at PLAN time. Otherwise the first symptom is a
    # task that cannot pull its image, discovered during a deploy.
    condition     = var.image_digest == "" || can(regex("^sha256:[0-9a-f]{64}$", var.image_digest))
    error_message = "image_digest must be empty or a full digest of the form sha256:<64 lowercase hex>."
  }
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

variable "idle_timeout_seconds" {
  type        = number
  description = "ALB connection idle timeout. AWS's own ALB default (60s) is too short for a slow client upload (e.g. a large git push) that keeps sending bytes past a minute -- raise it per-service when that's a real workload, not just for cushion."
  default     = 60
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
