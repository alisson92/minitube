import http from "k6/http";
import { check } from "k6";

// Phase 6 breakpoint test -- k6's own documented test type for exactly this
// goal ("breakpoint testing": ramp load until the system actually breaks,
// then stop). Complements load/k6/baseline.js, which is a fixed, small/
// growing load already validated to hold (0% errors, p95 well under the
// SLO -- see docs/runbooks/load/run-k6-baseline.md). This script does NOT try
// to hold any SLO -- its thresholds exist only to detect breakage and
// auto-abort (abortOnFail), instead of running a fixed duration blindly
// against an already-crashed target. Its own PEAK_RATE=800 result is what
// the current SLO's critical threshold (800ms, slo-rules.yaml) is based on
// -- see docs/runbooks/load/run-k6-breakpoint.md.
//
// Targets the API path on purpose (/api/healthz, /api/videos/{id} via the
// ALB -> the single Deployment replica with no HPA, see gitops/app/deployment.yaml)
// since that's the piece of the architecture without any scaling mitigation
// yet -- CloudFront/S3 (the "viewers" traffic) is kept as a small constant
// background load, not the target of this test.
//
// Open model (ramping-arrival-rate), not closed model (ramping-vus): a
// closed model self-throttles once responses slow down (VUs just queue up
// waiting for a response before making the next request), which can hide
// the real breaking point. An open model keeps firing requests at the
// target rate regardless of response time, so queueing/errors actually
// surface in the metrics -- this is what k6's own breakpoint-testing guide
// recommends.
//
// Usage: PEAK_RATE=<req/s, default 400> load/run-breakpoint.sh
// If the run completes cleanly (no abort), the system held past PEAK_RATE --
// rerun with a higher PEAK_RATE to keep escalating. See
// docs/runbooks/load/run-k6-breakpoint.md.

const BASE_URL = __ENV.BASE_URL;
const VIDEO_ID = __ENV.VIDEO_ID;
const PEAK_RATE = Number(__ENV.PEAK_RATE || 400);

export const options = {
  scenarios: {
    viewers_background: {
      executor: "constant-vus",
      exec: "viewers",
      vus: 10,
      duration: "17m",
    },
    api_breakpoint: {
      executor: "ramping-arrival-rate",
      exec: "apiDynamic",
      startRate: 5,
      timeUnit: "1s",
      preAllocatedVUs: Math.max(50, Math.round(PEAK_RATE / 4)),
      maxVUs: Math.max(200, PEAK_RATE * 2),
      stages: [
        { duration: "2m", target: Math.round(PEAK_RATE * 0.05) },
        { duration: "2m", target: Math.round(PEAK_RATE * 0.125) },
        { duration: "2m", target: Math.round(PEAK_RATE * 0.25) },
        { duration: "2m", target: Math.round(PEAK_RATE * 0.5) },
        { duration: "2m", target: PEAK_RATE },
        { duration: "5m", target: PEAK_RATE },
      ],
    },
  },
  thresholds: {
    "http_req_failed": [
      { threshold: "rate<0.05", abortOnFail: true, delayAbortEval: "10s" },
    ],
    "http_req_duration{endpoint:api}": [
      { threshold: "p(95)<1000", abortOnFail: true, delayAbortEval: "10s" },
    ],
  },
};

export function setup() {
  if (!BASE_URL || !VIDEO_ID) {
    throw new Error(
      "BASE_URL and VIDEO_ID env vars are required -- run this via load/run-breakpoint.sh, not k6 directly"
    );
  }

  const playlistUrl = `${BASE_URL}/hls/${VIDEO_ID}/playlist.m3u8`;
  const res = http.get(playlistUrl);
  if (res.status !== 200) {
    throw new Error(`could not fetch seed playlist at ${playlistUrl}: HTTP ${res.status}`);
  }

  const segmentNames = res.body
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#"));

  const segmentUrls = segmentNames.map((name) => `${BASE_URL}/hls/${VIDEO_ID}/${name}`);

  return { playlistUrl, segmentUrls };
}

export function viewers(data) {
  const playlistRes = http.get(data.playlistUrl, { tags: { endpoint: "playlist" } });
  check(playlistRes, { "playlist status is 200": (r) => r.status === 200 });

  for (const segmentUrl of data.segmentUrls) {
    const segmentRes = http.get(segmentUrl, { tags: { endpoint: "segment" } });
    check(segmentRes, { "segment status is 200": (r) => r.status === 200 });
  }
}

export function apiDynamic() {
  const healthRes = http.get(`${BASE_URL}/api/healthz`, { tags: { endpoint: "api" } });
  check(healthRes, { "healthz status is 200": (r) => r.status === 200 });

  const statusRes = http.get(`${BASE_URL}/api/videos/${VIDEO_ID}`, { tags: { endpoint: "api" } });
  check(statusRes, { "video status is 200": (r) => r.status === 200 });
}
