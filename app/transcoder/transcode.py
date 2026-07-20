import mimetypes
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import boto3

BUCKET = os.environ["S3_BUCKET"]
RAW_KEY = os.environ["S3_RAW_KEY"]
HLS_PREFIX = os.environ["S3_HLS_PREFIX"]
REGION = os.environ.get("AWS_REGION", "us-east-1")

# Single rendition for now (720p, 4s segments) — this phase only needs to
# prove FFmpeg -> HLS -> S3 works end to end. Multi-bitrate adaptive
# streaming is a separate concern for whenever the project actually load
# tests playback quality switching.
FFMPEG_ARGS = [
    "-vf", "scale=-2:720,format=yuv420p",
    "-c:v", "h264",
    "-profile:v", "main",
    "-crf", "20",
    "-c:a", "aac",
    "-ar", "48000",
    "-b:a", "128k",
    "-hls_time", "4",
    "-hls_playlist_type", "vod",
    "-hls_segment_filename", "segment_%03d.ts",
]


def main() -> None:
    s3 = boto3.client("s3", region_name=REGION)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        suffix = RAW_KEY.rsplit(".", 1)[-1] if "." in RAW_KEY else "bin"
        input_path = tmp_path / f"input.{suffix}"
        output_dir = tmp_path / "output"
        output_dir.mkdir()
        playlist_path = output_dir / "playlist.m3u8"

        print(f"Downloading s3://{BUCKET}/{RAW_KEY}", flush=True)
        s3.download_file(BUCKET, RAW_KEY, str(input_path))

        cmd = ["ffmpeg", "-y", "-i", str(input_path), *FFMPEG_ARGS, str(playlist_path)]
        print(f"Running: {' '.join(cmd)}", flush=True)
        subprocess.run(cmd, cwd=output_dir, check=True)

        output_files = sorted(output_dir.iterdir())
        if not output_files:
            print("FFmpeg produced no output files", file=sys.stderr)
            sys.exit(1)

        for f in output_files:
            key = f"{HLS_PREFIX}{f.name}"
            content_type, _ = mimetypes.guess_type(f.name)
            if f.suffix == ".m3u8":
                content_type = "application/vnd.apple.mpegurl"
            elif f.suffix == ".ts":
                content_type = "video/mp2t"
            print(f"Uploading s3://{BUCKET}/{key}", flush=True)
            s3.upload_file(str(f), BUCKET, key, ExtraArgs={"ContentType": content_type or "application/octet-stream"})

    print(f"Done: {len(output_files)} files uploaded to s3://{BUCKET}/{HLS_PREFIX}", flush=True)


if __name__ == "__main__":
    main()
