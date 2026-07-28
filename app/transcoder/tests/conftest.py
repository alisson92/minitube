import os
import sys
from pathlib import Path

# transcode.py is a flat script, not a package -- put app/transcoder on
# sys.path so tests can import it the same way.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# Read via os.environ[...] (no default) at import time -- must be set
# before anything imports transcode.
os.environ.setdefault("S3_BUCKET", "test-bucket")
os.environ.setdefault("S3_RAW_KEY", "raw/abc123.mp4")
os.environ.setdefault("S3_HLS_PREFIX", "hls/abc123/")
