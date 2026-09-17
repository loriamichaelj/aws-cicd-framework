data "aws_caller_identity" "current" {}

output "aws_account_id" {
  description = "AWS account the framework is deployed into."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region the framework is deployed into."
  value       = var.aws_region
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC identity provider in use."
  value       = local.oidc_provider_arn
}

output "deploy_role_arns" {
  description = "Per-environment deploy role ARNs, to be set as the IAM_ROLE_ARN variable in each GitHub Environment."
  value       = { for env, role in aws_iam_role.deploy : env => role.arn }
}

output "trusted_subjects" {
  description = "OIDC subject claims each environment role will accept."
  value       = local.trusted_subjects
}
