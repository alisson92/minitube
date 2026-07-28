import os
import sys
from pathlib import Path
from unittest.mock import patch

# main.py/jobs.py/s3_client.py use flat imports ("import jobs"), not a
# package -- put app/api on sys.path so the tests can import them the same way.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# config.Settings reads these via os.environ[...] (no default) at import
# time -- must be set before anything imports config/jobs/s3_client/main.
os.environ.setdefault("S3_BUCKET", "test-bucket")
os.environ.setdefault("TRANSCODER_IMAGE", "test-transcoder:latest")

# jobs.py calls this unconditionally at import time; outside a real pod it
# raises ConfigException, so every test run needs it patched before the
# first "import jobs" (directly, or transitively via "import main").
patch("kubernetes.config.load_incluster_config").start()
