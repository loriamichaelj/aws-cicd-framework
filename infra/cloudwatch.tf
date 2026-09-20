resource "aws_cloudwatch_log_group" "environment" {
  for_each = toset(["dev", "stage", "prod"])

  name              = "/aws-cicd/${each.key}"
  retention_in_days = 30
}
