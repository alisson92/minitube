# Image registry for the app's two container images (api, transcoder).
# Lives here, not in bootstrap-iam: ECR is not restricted by PowerUserAccess,
# so the daily operator can manage it without a CloudShell/root session.
# Persistent by design — rebuilding images every session would be wasteful,
# and the registry itself isn't part of the ephemeral envs/lab test cycle.
resource "aws_ecr_repository" "api" {
  name = "${var.project}-api"

  # Enforces a real tag per build (never :latest) — the tag becomes part of
  # the Kubernetes Deployment manifest committed to gitops/app/.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "transcoder" {
  name = "${var.project}-transcoder"

  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}
