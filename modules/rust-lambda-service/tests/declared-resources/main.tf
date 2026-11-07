# Test helper for config_secret.tftest.hcl: which resource and data types the
# module's own .tf files, and the one module it calls, declare. A
# terraform test assertion can see resources only by name, so it cannot
# otherwise prove a type is absent.

variable "dirs" {
  description = "Module directories to scan."
  type        = list(string)
}

locals {
  sources = flatten([for d in var.dirs : [for f in fileset(d, "*.tf") : file("${d}/${f}")]])
}

output "types" {
  description = "Every \"<resource|data> <type>\" declared, e.g. \"resource aws_lambda_function\"."
  value = toset(flatten([
    for src in local.sources : [
      for m in regexall("(?m)^\\s*(resource|data)\\s+\"([a-z0-9_]+)\"", src) : "${m[0]} ${m[1]}"
    ]
  ]))
}
