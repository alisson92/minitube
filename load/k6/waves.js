import http from "k6/http";
import { check, sleep } from "k6";

// Phase 6 waves scenario: simulates audience rising and falling in waves
// ("pré-jogo" -> "1º tempo" -> "intervalo" -> "2º tempo" -> "pico do gol" ->
// "apito final"), unlike load/k6/baseline.js (monotonic growth, already
// validated stable) and load/k6/breakpoint.js (ramp until it breaks, no
// descent). Neither of those exercises the HPA scaling back DOWN -- both
// only go up. This one does, on purpose: docs/adr/012-hpa-cpu-autoscaling.md
// added minReplicas:2/maxReplicas:6, but nothing so far has watched replicas
// come back down after a peak, only go up under sustained one-directional
// load.
//
// The "pico do gol" stage deliberately targets a rate at or near the real
// ceiling found in docs/runbooks/load/run-k6-breakpoint.md ("Resultado da
// execução via EC2, PEAK_RATE=800"): maxReplicas:6 * limits.cpu:500m = 3
// aggregate cores, which starts queueing (latency climbing, not errors)
// once combined demand crosses roughly 700-800 req/s. Crossing that
// deliberately here -- and then descending -- is what makes this a
// recovery test, not just another breakpoint run: does latency come back
// down and do replicas scale back to 2 once the wave passes, or does
// something get stuck?
//
// No abortOnFail on any threshold: the point is to observe the full shape
// (including planned degradation at the peak and recovery afterwards), not
// to stop at the first breach like breakpoint.js does.
//
// Usage: WAVE_PEAK_RATE=<req/s, default 700> load/run-waves.sh
// See docs/runbooks/load/run-k6-waves.md.

const BASE_URL = __ENV.BASE_URL;
const VIDEO_ID = __ENV.VIDEO_ID;
const WAVE_PEAK_RATE = Number(__ENV.WAVE_PEAK_RATE || 700);

function pct(fraction) {
  return Math.max(1, Math.round(WAVE_PEAK_RATE * fraction));
}

export const options = {
  scenarios: {
    // Mirrors the api_dynamic wave shape below with VU counts instead of a
    // request rate -- CloudFront/S3 traffic isn't the target of this test
    // (it never broke in any previous run), but real audience size should
    // still rise and fall with the "match", not stay flat like breakpoint.js's
    // constant 10-VU background.
    viewers: {
      executor: "ramping-vus",
      exec: "viewers",
      startVUs: 0,
      stages: [
        { duration: "3m", target: 5 }, // pré-jogo: torcida chegando
        { duration: "4m", target: 30 }, // 1º tempo: carga sustentada moderada
        { duration: "2m", target: 5 }, // intervalo: queda abrupta
        { duration: "3m", target: 5 }, // intervalo: vale sustentado (testa scale-down do HPA)
        { duration: "3m", target: 40 }, // 2º tempo: torcida volta, mais gente que o 1º tempo
        { duration: "2m", target: 80 }, // pico do gol: rampa até o pico
        { duration: "2m", target: 80 }, // pico do gol: sustentado no pico
        { duration: "2m", target: 5 }, // apito final: queda para quase zero
        { duration: "2m", target: 5 }, // apito final: vale final sustentado
      ],
    },
    api_dynamic: {
      executor: "ramping-arrival-rate",
      exec: "apiDynamic",
      startRate: 5,
      timeUnit: "1s",
      preAllocatedVUs: Math.max(50, Math.round(WAVE_PEAK_RATE / 4)),
      maxVUs: Math.max(200, WAVE_PEAK_RATE * 2),
      stages: [
        { duration: "3m", target: pct(0.15) }, // pré-jogo: torcida chegando
        { duration: "4m", target: pct(0.35) }, // 1º tempo: carga sustentada moderada
        { duration: "2m", target: pct(0.05) }, // intervalo: queda abrupta
        { duration: "3m", target: pct(0.05) }, // intervalo: vale sustentado (testa scale-down do HPA)
        { duration: "3m", target: pct(0.45) }, // 2º tempo: torcida volta, mais gente que o 1º tempo
        { duration: "2m", target: WAVE_PEAK_RATE }, // pico do gol: rampa até o pico deliberado
        { duration: "2m", target: WAVE_PEAK_RATE }, // pico do gol: sustentado no pico (esperado: latência sobe, sem erros -- ver docs/runbooks/load/run-k6-breakpoint.md)
        { duration: "2m", target: pct(0.03) }, // apito final: queda para quase zero
        { duration: "2m", target: pct(0.03) }, // apito final: vale final sustentado (confirma recuperação e scale-down)
      ],
    },
  },
  // Observational only, no abortOnFail -- the SLO's critical threshold
  // (APILatencyCritical, 800ms in slo-rules.yaml) is expected to be
  // breached during the "pico do gol" stage on purpose (that data point is
  // in fact what the threshold is based on -- see
  // docs/runbooks/load/run-k6-breakpoint.md). Read the actual numbers from the
  // k6 summary and Prometheus, don't rely on pass/fail here.
  thresholds: {
    "http_req_failed": ["rate<0.05"],
    "http_req_duration{endpoint:api}": ["p(95)<1000"],
  },
};

export function setup() {
  if (!BASE_URL || !VIDEO_ID) {
    throw new Error(
      "BASE_URL and VIDEO_ID env vars are required -- run this via load/run-waves.sh or load/run-waves-from-ec2.sh, not k6 directly"
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
}

export function apiDynamic() {
  const healthRes = http.get(`${BASE_URL}/api/healthz`, { tags: { endpoint: "api" } });
  check(healthRes, { "healthz status is 200": (r) => r.status === 200 });

  const statusRes = http.get(`${BASE_URL}/api/videos/${VIDEO_ID}`, { tags: { endpoint: "api" } });
  check(statusRes, { "video status is 200": (r) => r.status === 200 });
}
