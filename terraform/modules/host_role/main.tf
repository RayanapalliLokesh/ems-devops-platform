# The host's identity: backups to S3 and image pulls from ECR without any key on the machine
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-host-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "host" {
  statement {
    sid       = "BackupBucketList"
    actions   = ["s3:ListBucket"]
    resources = [var.backup_bucket_arn]
  }
  statement {
    sid       = "BackupObjects"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${var.backup_bucket_arn}/backups/*"]
  }
  statement {
    sid       = "EcrToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = var.ecr_repository_arns
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["arn:aws:logs:*:*:log-group:/ems/*"]
  }
}

# A managed policy plus an attachment (the playground does not allow inline role policies)
resource "aws_iam_policy" "host" {
  provider = aws.untagged # the playground forbids iam:TagPolicy
  name     = "${var.name}-host-policy"
  policy   = data.aws_iam_policy_document.host.json
}

resource "aws_iam_role_policy_attachment" "host" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.host.arn
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-host-profile"
  role = aws_iam_role.this.name
  tags = var.tags
}
