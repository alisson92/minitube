# Chaos: kill an API pod under load

## What

`chaos/kill-api-pod.sh` generates light traffic against `/api/healthz` (via `port-forward`) and, midway through the window, deletes one of the `api` replica's pods (`kubectl delete pod`). It measures the client-side error rate throughout the whole window and confirms the `ReplicaSet` recreates the pod.

## Why

`gitops/app/hpa.yaml` sets `minReplicas: 2` and `gitops/app/pdb.yaml` guarantees `minAvailable: 1`. The mere existence of these objects doesn't prove that losing one pod is absorbed without noticeable impact — only a real test does (`docs/engineering-standards.md` §11).

## How

```bash
AWS_PROFILE=cloudlab ./chaos/kill-api-pod.sh
```

Optional environment variables:
- `TRAFFIC_WINDOW_SECONDS` (default 90) — total duration of the traffic window.
- `KILL_AFTER_SECONDS` (default 15) — when, within the window, the pod is killed.
- `MAX_ERROR_RATE_PERCENT` (default 1) — PASS/FAIL threshold.

Nothing needs to be reverted on the cluster at the end — Kubernetes recreates the deleted pod on its own, that *is* the behavior under test. The script only cleans up the local `port-forward` and temporary files (`trap cleanup EXIT`).

## How to read the result

- **PASS:** client error rate stayed within the threshold — losing a pod wasn't visible to API consumers.
- **FAIL:** error rate above the threshold. Investigate:
  - `kubectl -n minitube-app get hpa api` — did the replacement replica take too long to become `Ready`? (`readinessProbe` in `gitops/app/deployment.yaml`, `initialDelaySeconds: 5`/`periodSeconds: 10`)
  - `kubectl -n minitube-app describe pdb api` — did the PDB block any concurrent disruption?
  - If `ready_replicas < 2` in the pre-check, the script fails before it starts — the Deployment needs to already have the HPA stabilized at at least 2 replicas.

## Run result (2026-07-26) — PASS

Run against the real infra (2 ready replicas, HPA at `cpu: 3%/70%`). Pod `api-7b868f7f45-kmvv6` deleted 15s into the window; the `ReplicaSet` created `api-7b868f7f45-m6zlg` right after.

- **Total requests:** 94 (90s window, one every 0.5s).
- **Non-200:** 0.
- **Error rate:** 0%.

`PASS`: `minReplicas: 2` + the `PodDisruptionBudget` absorbed the pod loss with no noticeable client-side impact — exactly the expected behavior.
