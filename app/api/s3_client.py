from typing import BinaryIO

import boto3
from botocore.exceptions import ClientError
from config import settings

_s3 = boto3.client("s3", region_name=settings.aws_region)


def raw_key(video_id: str, filename: str) -> str:
    suffix = filename.rsplit(".", 1)[-1] if "." in filename else "bin"
    return f"raw/{video_id}.{suffix}"


def hls_prefix(video_id: str) -> str:
    return f"hls/{video_id}/"


def upload_raw_video(fileobj: BinaryIO, key: str) -> None:
    _s3.upload_fileobj(fileobj, settings.s3_bucket, key)


def hls_playlist_exists(video_id: str) -> bool:
    try:
        _s3.head_object(Bucket=settings.s3_bucket, Key=f"{hls_prefix(video_id)}playlist.m3u8")
        return True
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "404":
            return False
        raise
