from unittest.mock import MagicMock

import pytest
import s3_client
from botocore.exceptions import ClientError


@pytest.fixture(autouse=True)
def mock_s3(monkeypatch):
    mock = MagicMock()
    monkeypatch.setattr(s3_client, "_s3", mock)
    return mock


def test_raw_key_keeps_extension():
    assert s3_client.raw_key("abc123", "movie.mp4") == "raw/abc123.mp4"


def test_raw_key_defaults_to_bin_without_extension():
    assert s3_client.raw_key("abc123", "movie") == "raw/abc123.bin"


def test_hls_prefix():
    assert s3_client.hls_prefix("abc123") == "hls/abc123/"


def test_upload_raw_video_calls_s3_upload_fileobj(mock_s3):
    fileobj = MagicMock()

    s3_client.upload_raw_video(fileobj, "raw/abc123.mp4")

    mock_s3.upload_fileobj.assert_called_once_with(fileobj, "test-bucket", "raw/abc123.mp4")


def test_hls_playlist_exists_true(mock_s3):
    mock_s3.head_object.return_value = {}

    assert s3_client.hls_playlist_exists("abc123") is True
    mock_s3.head_object.assert_called_once_with(
        Bucket="test-bucket", Key="hls/abc123/playlist.m3u8"
    )


def test_hls_playlist_exists_false_on_404(mock_s3):
    mock_s3.head_object.side_effect = ClientError(
        {"Error": {"Code": "404", "Message": "Not Found"}}, "HeadObject"
    )

    assert s3_client.hls_playlist_exists("abc123") is False


def test_hls_playlist_exists_reraises_other_errors(mock_s3):
    mock_s3.head_object.side_effect = ClientError(
        {"Error": {"Code": "403", "Message": "Forbidden"}}, "HeadObject"
    )

    with pytest.raises(ClientError):
        s3_client.hls_playlist_exists("abc123")
