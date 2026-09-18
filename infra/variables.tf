variable "aws_region" {
  description = "AWS region for all framework resources."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short logical project name, used for tagging and resource name prefixes."
  type        = string
  default     = "aws-cicd"
}

variable "github_owner" {
  description = "GitHub user or organisation that owns the framework and consumer repositories."
  type        = string
  default     = "loriamichaelj"
}
