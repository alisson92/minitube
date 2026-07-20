import uuid

from fastapi import FastAPI, HTTPException, UploadFile

import jobs
import s3_client

app = FastAPI(title="minitube-api")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/videos")
def upload_video(file: UploadFile):
    video_id = uuid.uuid4().hex
    raw_key = s3_client.raw_key(video_id, file.filename or "video")
    hls_prefix = s3_client.hls_prefix(video_id)

    s3_client.upload_raw_video(file.file, raw_key)
    job_name = jobs.create_transcode_job(video_id, raw_key, hls_prefix)

    return {"video_id": video_id, "job_name": job_name, "status": "queued"}


@app.get("/videos/{video_id}")
def get_video_status(video_id: str):
    status = jobs.get_job_status(video_id)
    if status == "not_found":
        raise HTTPException(status_code=404, detail="video not found")
    return {"video_id": video_id, "status": status}
