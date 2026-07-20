from kubernetes import client, config

from config import settings

# In-cluster only: the API always runs as a pod (see gitops/app/deployment.yaml),
# never locally against a kubeconfig.
config.load_incluster_config()
_batch = client.BatchV1Api()


def _job_name(video_id: str) -> str:
    return f"transcode-{video_id}"


def create_transcode_job(video_id: str, raw_key: str, hls_prefix: str) -> str:
    name = _job_name(video_id)

    container = client.V1Container(
        name="transcoder",
        image=settings.transcoder_image,
        env=[
            client.V1EnvVar(name="S3_BUCKET", value=settings.s3_bucket),
            client.V1EnvVar(name="S3_RAW_KEY", value=raw_key),
            client.V1EnvVar(name="S3_HLS_PREFIX", value=hls_prefix),
            client.V1EnvVar(name="AWS_REGION", value=settings.aws_region),
        ],
        resources=client.V1ResourceRequirements(
            requests={"cpu": "250m", "memory": "256Mi"},
            limits={"cpu": "1", "memory": "1Gi"},
        ),
    )

    pod_spec = client.V1PodSpec(
        service_account_name=settings.transcoder_service_account,
        restart_policy="Never",
        containers=[container],
    )

    job = client.V1Job(
        metadata=client.V1ObjectMeta(
            name=name,
            labels={
                "app.kubernetes.io/name": "transcoder",
                "app.kubernetes.io/part-of": "minitube",
                "app.kubernetes.io/managed-by": "minitube-api",
            },
        ),
        spec=client.V1JobSpec(
            template=client.V1PodTemplateSpec(spec=pod_spec),
            backoff_limit=0,
            active_deadline_seconds=600,
            # Auto-cleans finished Job/Pod objects so completed transcodes
            # don't accumulate in the namespace between test runs.
            ttl_seconds_after_finished=3600,
        ),
    )

    _batch.create_namespaced_job(namespace=settings.job_namespace, body=job)
    return name


def get_job_status(video_id: str) -> str:
    name = _job_name(video_id)
    try:
        # read_namespaced_job, not read_namespaced_job_status: the latter
        # hits the /status subresource, which needs a separate RBAC grant
        # ("jobs/status", not just "jobs") that gitops/app/role.yaml doesn't
        # have. read_namespaced_job returns the same .status field and only
        # needs "get" on jobs, which the Role already covers.
        job = _batch.read_namespaced_job(name=name, namespace=settings.job_namespace)
    except client.ApiException as exc:
        if exc.status == 404:
            return "not_found"
        raise

    status = job.status
    if status.succeeded:
        return "succeeded"
    if status.failed:
        return "failed"
    return "running"
