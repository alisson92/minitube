import http from "k6/http";
import { check } from "k6";

// k6's documented "breakpoint testing" pattern: ramp load until the system
// actually breaks, then stop (abortOnFail thresholds), unlike
// baseline.js's fixed small/growing load already validated to hold. Its
// own PEAK_RATE=800 result is what the SLO's critical threshold (800ms,
// slo-rules.yaml) is based on -- see docs/runbooks/load/run-k6-breakpoint.md.
//
// Targets the API path (no HPA mitigation on this Deployment yet at the
// time this was written -- see gitops/app/deployment.yaml); CloudFront/S3
// stays a small constant background load, not this test's target. Open
// model (ramping-arrival-rate), not closed (ramping-vus): a closed model
// self-throttles as responses slow down, hiding the real breaking point.
//
// Usage: PEAK_RATE=<req/s, default 400> load/run-breakpoint.sh
// A clean run (no abort) means the system held past PEAK_RATE -- rerun
// with a higher PEAK_RATE to keep escalating.

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
