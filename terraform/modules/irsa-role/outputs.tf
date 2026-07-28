output "role_arn" {
  description = "ARN of the IAM role"
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.this.name
}

output "role_id" {
  description = "ID of the IAM role (same as its name -- exposed for callers that attach aws_iam_role_policy/aws_iam_role_policy_attachment by id, matching those resources' own attribute name)"
  value       = aws_iam_role.this.id
}
