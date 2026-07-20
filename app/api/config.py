import os


class Settings:
    s3_bucket: str = os.environ["S3_BUCKET"]
    aws_region: str = os.environ.get("AWS_REGION", "us-east-1")
    job_namespace: str = os.environ.get("JOB_NAMESPACE", "minitube-app")
    transcoder_image: str = os.environ["TRANSCODER_IMAGE"]
    transcoder_service_account: str = os.environ.get("TRANSCODER_SERVICE_ACCOUNT", "transcoder")


settings = Settings()
