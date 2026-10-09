# Phase 21 - the host role: a customer-managed policy created through the untagged provider plus an attachment
# (the playground denies iam:PutRolePolicy and iam:TagPolicy)
mock_provider "aws" {
  # the real provider validates policy JSON even with a mock, so the documents return a valid empty policy
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "aws" {
  alias = "untagged"
}

variables {
  name                = "ems-test"
  backup_bucket_arn   = "arn:aws:s3:::ems-test-backups-0a1b2c3d"
  ecr_repository_arns = ["arn:aws:ecr:us-east-1:123456789012:repository/ems-app"]
}

run "role_policy_and_profile" {
  command = plan

  assert {
    condition     = aws_iam_role.this.name == "ems-test-host-role"
    error_message = "The role is named <name>-host-role."
  }
  assert {
    condition     = aws_iam_policy.host.name == "ems-test-host-policy"
    error_message = "The permissions live in a managed policy, not an inline role policy."
  }
  assert {
    condition     = aws_iam_instance_profile.this.name == "ems-test-host-profile" && aws_iam_instance_profile.this.role == "ems-test-host-role"
    error_message = "The instance profile wraps the host role."
  }
}
