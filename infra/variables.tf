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

variable "consumer_repos" {
  description = "Calling repository names, without owner, permitted to assume the deploy roles via OIDC."
  type        = list(string)
  default = [
    "aws-cicd-demo-python-app",
    "aws-cicd-demo-node-app",
  ]
}

variable "environments" {
  description = "Deployment environments. One IAM role is created per entry."
  type        = list(string)
  default     = ["dev", "stage", "prod"]
}

variable "create_oidc_provider" {
  description = "Create the GitHub IAM OIDC provider. Set false when the account already has one for token.actions.githubusercontent.com."
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of a pre-existing GitHub OIDC provider. Required when create_oidc_provider is false."
  type        = string
  default     = ""

  validation {
    condition     = var.existing_oidc_provider_arn == "" || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/", var.existing_oidc_provider_arn))
    error_message = "existing_oidc_provider_arn must be empty or a valid IAM OIDC provider ARN."
  }
}

variable "role_name_prefix" {
  description = "Prefix for the per-environment deploy role names. 'gha-deploy' yields gha-deploy-dev."
  type        = string
  default     = "gha-deploy"
}

variable "max_session_duration" {
  description = "Maximum lifetime in seconds of credentials obtained by assuming a deploy role."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 900 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 900 and 43200 seconds."
  }
}
