import http from "k6/http";
import { check, sleep } from "k6";

// Phase 6 baseline scenario: deliberately small/growing load against the
// CURRENT setup -- API Deployment fixed at 1 replica, EKS node group fixed
// at 3/3/3, no HPA/Cluster Autoscaler (see gitops/app/deployment.yaml and
// terraform/envs/lab/variables.tf). The goal is to observe what breaks first
// with no scaling mitigation in place, before deciding what to add. See
// docs/runbooks/run-k6-baseline.md for how this fits into the rest of the
// phase and how to read the result.
//
// Two scenarios run in parallel, mirroring the two traffic flows in the
// architecture (CLAUDE.md): most requests should die at CloudFront ("viewers"),
// while a much smaller volume of dynamic traffic reaches the API through the
// ALB ("api_dynamic"). Video upload/transcoding is intentionally NOT part of
// this baseline -- spinning up concurrent transcode Jobs is a heavier,
// separate stress scenario, not a small/growing baseline one.

const BASE_URL = __ENV.BASE_URL;
const VIDEO_ID = __ENV.VIDEO_ID;

export const options = {
  scenarios: {
    viewers: {
      executor: "ramping-vus",
      exec: "viewers",
      startVUs: 0,
      stages: [
        { duration: "30s", target: 5 },
        { duration: "1m", target: 20 },
        { duration: "2m", target: 20 },
        { duration: "1m", target: 50 },
        { duration: "2m", target: 50 },
        { duration: "30s", target: 0 },
      ],
    },
    api_dynamic: {
      executor: "ramping-vus",
      exec: "apiDynamic",
      startVUs: 0,
      stages: [
        { duration: "30s", target: 2 },
        { duration: "1m", target: 5 },
        { duration: "2m", target: 5 },
        { duration: "1m", target: 10 },
        { duration: "2m", target: 10 },
        { duration: "30s", target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.01"],
    "http_req_duration{endpoint:playlist}": ["p(95)<500"],
    "http_req_duration{endpoint:segment}": ["p(95)<500"],
    // matches APILatencyWarning in gitops/platform/kube-prometheus-stack/slo-rules.yaml --
    // revised in Phase 6 from the original 500ms placeholder using this
    // script's own first result (p95=186ms) plus the breakpoint/waves data.
    "http_req_duration{endpoint:api}": ["p(95)<250"],
  },
};

function randomIntBetween(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

export function setup() {
  if (!BASE_URL || !VIDEO_ID) {
    throw new Error(
      "BASE_URL and VIDEO_ID env vars are required -- run this via load/run-baseline.sh, not k6 directly"
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
    sleep(1); // roughly paces segment fetches like real playback, not a burst
  }

  sleep(randomIntBetween(1, 3)); // pause before this VU "replays" the video
}

export function apiDynamic() {
  const healthRes = http.get(`${BASE_URL}/api/healthz`, { tags: { endpoint: "api" } });
  check(healthRes, { "healthz status is 200": (r) => r.status === 200 });

  const statusRes = http.get(`${BASE_URL}/api/videos/${VIDEO_ID}`, { tags: { endpoint: "api" } });
  check(statusRes, { "video status is 200": (r) => r.status === 200 });

  sleep(randomIntBetween(2, 5));
}
