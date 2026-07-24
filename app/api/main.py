import uuid

from fastapi import APIRouter, FastAPI, HTTPException, UploadFile
from prometheus_fastapi_instrumentator import Instrumentator

import jobs
import s3_client

app = FastAPI(title="minitube-api")

# CloudFront's /api/* cache behavior (terraform/envs/lab/cloudfront.tf)
# forwards paths to the ALB unmodified -- the ALB Ingress controller doesn't
# support path rewriting, so the app must serve every route under /api
# itself to be reachable from the public app.<domain> URL.
router = APIRouter(prefix="/api")


@router.get("/healthz")
def healthz():
    return {"status": "ok"}


@router.post("/videos")
def upload_video(file: UploadFile):
    video_id = uuid.uuid4().hex
    raw_key = s3_client.raw_key(video_id, file.filename or "video")
    hls_prefix = s3_client.hls_prefix(video_id)

    s3_client.upload_raw_video(file.file, raw_key)
    job_name = jobs.create_transcode_job(video_id, raw_key, hls_prefix)

    return {"video_id": video_id, "job_name": job_name, "status": "queued"}


@router.get("/videos/{video_id}")
def get_video_status(video_id: str):
    status = jobs.get_job_status(video_id)
    if status == "not_found":
        raise HTTPException(status_code=404, detail="video not found")
    return {"video_id": video_id, "status": status}


app.include_router(router)

# Exposed at /metrics (root, outside the /api prefix) -- only scraped
# in-cluster by the Prometheus ServiceMonitor via the Service's ClusterIP,
# never through CloudFront/the ALB (which only forward /api/*), so the
# /api-prefix constraint above doesn't apply here.
Instrumentator().instrument(app).expose(app)
