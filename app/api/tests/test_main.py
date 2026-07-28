import io
from unittest.mock import MagicMock

import main
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client():
    return TestClient(main.app)


def test_healthz(client):
    response = client.get("/api/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_upload_video_returns_queued_status(client, monkeypatch):
    monkeypatch.setattr(main.s3_client, "upload_raw_video", MagicMock())
    monkeypatch.setattr(main.jobs, "create_transcode_job", MagicMock(return_value="transcode-abc123"))

    response = client.post(
        "/api/videos", files={"file": ("movie.mp4", io.BytesIO(b"fake-bytes"), "video/mp4")}
    )

    assert response.status_code == 200
    body = response.json()
    assert body["job_name"] == "transcode-abc123"
    assert body["status"] == "queued"
    assert len(body["video_id"]) == 32  # uuid4().hex


def test_upload_video_uses_returned_video_id_for_s3_and_job(client, monkeypatch):
    upload_mock = MagicMock()
    job_mock = MagicMock(return_value="transcode-xyz")
    monkeypatch.setattr(main.s3_client, "upload_raw_video", upload_mock)
    monkeypatch.setattr(main.jobs, "create_transcode_job", job_mock)

    response = client.post(
        "/api/videos", files={"file": ("movie.mp4", io.BytesIO(b"fake-bytes"), "video/mp4")}
    )

    video_id = response.json()["video_id"]
    upload_mock.assert_called_once()
    assert upload_mock.call_args.args[1] == f"raw/{video_id}.mp4"
    job_mock.assert_called_once_with(video_id, f"raw/{video_id}.mp4", f"hls/{video_id}/")


def test_get_video_status_returns_status(client, monkeypatch):
    monkeypatch.setattr(main.jobs, "get_job_status", MagicMock(return_value="running"))

    response = client.get("/api/videos/abc123")

    assert response.status_code == 200
    assert response.json() == {"video_id": "abc123", "status": "running"}


def test_get_video_status_404_when_not_found(client, monkeypatch):
    monkeypatch.setattr(main.jobs, "get_job_status", MagicMock(return_value="not_found"))

    response = client.get("/api/videos/abc123")

    assert response.status_code == 404
