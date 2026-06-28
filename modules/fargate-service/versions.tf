terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = ">= 5.0"
      # The caller passes a second aws provider (aws.parent_dns) configured for
      # the account that owns the parent DNS zone, used only for the NS
      # delegation record.
      configuration_aliases = [aws.parent_dns]
    }
  }
}
