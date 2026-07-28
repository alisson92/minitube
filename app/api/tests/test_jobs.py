from unittest.mock import MagicMock

import jobs
import pytest
from kubernetes.client import ApiException


@pytest.fixture(autouse=True)
def mock_batch(monkeypatch):
    mock = MagicMock()
    monkeypatch.setattr(jobs, "_batch", mock)
    return mock


def test_create_transcode_job_submits_job_with_expected_shape(mock_batch):
    job_name = jobs.create_transcode_job("abc123", "raw/abc123.mp4", "hls/abc123/")

    assert job_name == "transcode-abc123"
    mock_batch.create_namespaced_job.assert_called_once()

    _, kwargs = mock_batch.create_namespaced_job.call_args
    assert kwargs["namespace"] == "minitube-app"

    body = kwargs["body"]
    assert body.metadata.name == "transcode-abc123"

    container = body.spec.template.spec.containers[0]
    assert container.image == "test-transcoder:latest"
    env = {e.name: e.value for e in container.env}
    assert env == {
        "S3_BUCKET": "test-bucket",
        "S3_RAW_KEY": "raw/abc123.mp4",
        "S3_HLS_PREFIX": "hls/abc123/",
        "AWS_REGION": "us-east-1",
    }


def test_get_job_status_succeeded(mock_batch):
    job = MagicMock()
    job.status.succeeded = 1
    job.status.failed = None
    mock_batch.read_namespaced_job.return_value = job

    assert jobs.get_job_status("abc123") == "succeeded"


def test_get_job_status_failed(mock_batch):
    job = MagicMock()
    job.status.succeeded = None
    job.status.failed = 1
    mock_batch.read_namespaced_job.return_value = job

    assert jobs.get_job_status("abc123") == "failed"


def test_get_job_status_running(mock_batch):
    job = MagicMock()
    job.status.succeeded = None
    job.status.failed = None
    mock_batch.read_namespaced_job.return_value = job

    assert jobs.get_job_status("abc123") == "running"


def test_get_job_status_falls_back_to_s3_when_job_gone(mock_batch, monkeypatch):
    mock_batch.read_namespaced_job.side_effect = ApiException(status=404)
    monkeypatch.setattr(jobs.s3_client, "hls_playlist_exists", lambda video_id: True)

    assert jobs.get_job_status("abc123") == "succeeded"


def test_get_job_status_not_found_when_job_and_playlist_both_missing(mock_batch, monkeypatch):
    mock_batch.read_namespaced_job.side_effect = ApiException(status=404)
    monkeypatch.setattr(jobs.s3_client, "hls_playlist_exists", lambda video_id: False)

    assert jobs.get_job_status("abc123") == "not_found"


def test_get_job_status_reraises_non_404_errors(mock_batch):
    mock_batch.read_namespaced_job.side_effect = ApiException(status=500)

    with pytest.raises(ApiException):
        jobs.get_job_status("abc123")
