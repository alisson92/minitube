import subprocess
from pathlib import Path
from unittest.mock import MagicMock

import pytest
import transcode


@pytest.fixture(autouse=True)
def mock_s3(monkeypatch):
    mock = MagicMock()
    monkeypatch.setattr("boto3.client", MagicMock(return_value=mock))
    return mock


def fake_ffmpeg_run(*output_names):
    """subprocess.run replacement that fabricates ffmpeg's output files in cwd."""

    def _run(cmd, cwd=None, check=None):
        for name in output_names:
            (Path(cwd) / name).write_text("fake")
        return MagicMock(returncode=0)

    return _run


def test_main_downloads_transcodes_and_uploads_all_outputs(monkeypatch, mock_s3):
    monkeypatch.setattr(subprocess, "run", fake_ffmpeg_run("playlist.m3u8", "segment_000.ts"))

    transcode.main()

    mock_s3.download_file.assert_called_once()
    download_args = mock_s3.download_file.call_args.args
    assert download_args[0] == "test-bucket"
    assert download_args[1] == "raw/abc123.mp4"
    assert download_args[2].endswith("input.mp4")

    uploaded = {
        call.args[2]: call.kwargs["ExtraArgs"]["ContentType"]
        for call in mock_s3.upload_file.call_args_list
    }
    assert uploaded == {
        "hls/abc123/playlist.m3u8": "application/vnd.apple.mpegurl",
        "hls/abc123/segment_000.ts": "video/mp2t",
    }
    assert all(call.args[1] == "test-bucket" for call in mock_s3.upload_file.call_args_list)


def test_main_defaults_to_bin_suffix_when_raw_key_has_no_extension(monkeypatch, mock_s3):
    monkeypatch.setattr(transcode, "RAW_KEY", "raw/abc123")
    monkeypatch.setattr(subprocess, "run", fake_ffmpeg_run("playlist.m3u8"))

    transcode.main()

    input_path = mock_s3.download_file.call_args.args[2]
    assert input_path.endswith("input.bin")


def test_main_uses_generic_mimetype_guess_for_other_extensions(monkeypatch, mock_s3):
    monkeypatch.setattr(subprocess, "run", fake_ffmpeg_run("thumbnail.jpg"))

    transcode.main()

    call = mock_s3.upload_file.call_args_list[0]
    assert call.kwargs["ExtraArgs"]["ContentType"] == "image/jpeg"


def test_main_exits_with_error_when_ffmpeg_produces_no_output(monkeypatch, mock_s3):
    monkeypatch.setattr(subprocess, "run", fake_ffmpeg_run())

    with pytest.raises(SystemExit) as exc_info:
        transcode.main()

    assert exc_info.value.code == 1
    mock_s3.upload_file.assert_not_called()


def test_main_propagates_ffmpeg_failure(monkeypatch, mock_s3):
    def _raise(cmd, cwd=None, check=None):
        raise subprocess.CalledProcessError(returncode=1, cmd=cmd)

    monkeypatch.setattr(subprocess, "run", _raise)

    with pytest.raises(subprocess.CalledProcessError):
        transcode.main()

    mock_s3.download_file.assert_called_once()
    mock_s3.upload_file.assert_not_called()


def test_ffmpeg_cmd_includes_expected_flags(monkeypatch, mock_s3):
    captured = {}

    def _run(cmd, cwd=None, check=None):
        captured["cmd"] = cmd
        captured["cwd"] = cwd
        captured["check"] = check
        (Path(cwd) / "playlist.m3u8").write_text("fake")

    monkeypatch.setattr(subprocess, "run", _run)

    transcode.main()

    cmd = captured["cmd"]
    assert cmd[0] == "ffmpeg"
    assert cmd[cmd.index("-hls_time") + 1] == "4"
    assert cmd[cmd.index("-c:v") + 1] == "h264"
    assert cmd[-1].endswith("playlist.m3u8")
    assert captured["check"] is True
