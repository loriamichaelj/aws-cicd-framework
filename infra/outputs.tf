data "aws_caller_identity" "current" {}

output "aws_account_id" {
  description = "AWS account the framework is deployed into."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region the framework is deployed into."
  value       = var.aws_region
}

output "artifacts_bucket_name" {
  description = "S3 bucket for deployment manifests and saved container image tarballs. Set this as the S3_BUCKET GitHub Environment variable in each consumer repo."
  value       = aws_s3_bucket.artifacts.id
}
