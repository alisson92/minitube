# Image registry for the app's two container images. Lives here, not
# bootstrap-iam: ECR isn't restricted by PowerUserAccess. Persistent by
# design -- outside envs/lab's ephemeral cycle, rebuilding every session
# would be wasteful.
resource "aws_ecr_repository" "api" {
  name = "${var.project}-api"

  # Enforces a real tag per build (never :latest) — the tag becomes part of
  # the Kubernetes Deployment manifest committed to gitops/app/.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  # Allows `terraform destroy` to remove the repo even with images still
  # pushed to it (see docs/adr/001-terraform-state-backend.md#update).
  force_delete = true
}

resource "aws_ecr_repository" "transcoder" {
  name = "${var.project}-transcoder"

  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  force_delete = true
}
