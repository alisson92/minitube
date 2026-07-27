# load/

Phase 6 ("game day") k6 load test scenarios. Each `run-*.sh` script orchestrates: finding (or creating) a real, already-transcoded video (`lib/find-or-create-video.sh`), running the corresponding k6 scenario in `k6/`, and cleaning up any temporary resources at the end (`trap ... EXIT`).

| Script | k6 scenario | Where k6 runs | Runbook |
| ------ | ---------- | --------------- | ------- |
| `run-baseline.sh` | `k6/baseline.js` — small, ramping load, no intent to break anything | Local (operator's machine) | [`docs/runbooks/load/run-k6-baseline.md`](../docs/runbooks/load/run-k6-baseline.md) |
| `run-breakpoint.sh` | `k6/breakpoint.js` — ramp until it breaks | Local | [`docs/runbooks/load/run-k6-breakpoint.md`](../docs/runbooks/load/run-k6-breakpoint.md) |
| `run-breakpoint-from-ec2.sh` | `k6/breakpoint.js` (same scenario) | Ephemeral EC2 inside the VPC (via SSM, no public IP) | same runbook as above |
| `run-waves-from-ec2.sh` | `k6/waves.js` — audience rising and falling in waves | Ephemeral EC2 inside the VPC | [`docs/runbooks/load/run-k6-waves.md`](../docs/runbooks/load/run-k6-waves.md) |

## Why the local vs. EC2 coverage is asymmetric

It's not a gap — it's the direct result of a real problem found in this phase, documented in detail in `run-k6-breakpoint.md` ("Latency investigation" section): running k6 locally (operator → WSL2 → home ISP → internet → AWS) adds network noise the server side never sees. The first local `run-breakpoint.sh` aborted with `p95=1s`/`max=7.54s`, while the ALB's `TargetResponseTime` and the API's own internal latency (Prometheus) stayed fast (≤145ms/≤0.5s) in the same window — the slowness was in the client→AWS path, not the service.

This explains why each script has exactly the coverage it has, no more, no less:

- **`baseline.js` never needed an EC2 variant.** It's a small, deliberately non-aggressive load, already validated as stable (0% error) even running locally — the local path's network noise never came close to masking the result.
- **`breakpoint.js` has both variants** because it was exactly this scenario that exposed the problem: the local version exists (and documents the investigation itself), but the EC2 version (`run-breakpoint-from-ec2.sh`) is the one that produces the reliable result used to size the HPA (ADR 012).
- **`waves.js` only has the EC2 variant.** Created after the lesson above was already on record — running it locally from the start would introduce the same known noise, especially during the scale-down stages, where telling real latency apart from network noise matters as much as at the peak. There is no local `run-waves.sh` (nor would it make sense to create one) just for symmetry.

Both `-from-ec2` scripts reuse the same ephemeral-EC2-via-SSM pattern (private subnet, no SSH/bastion, always terminated via `trap`) already used by `terraform/envs/lab/scripts/validate-network.sh` — no new Terraform resource was created for them.
