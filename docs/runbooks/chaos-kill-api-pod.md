# Chaos: matar um pod da API sob carga

## O quê

`chaos/kill-api-pod.sh` gera tráfego leve contra `/api/healthz` (via `port-forward`) e, no meio da janela, deleta um dos pods da réplica `api` (`kubectl delete pod`). Mede a taxa de erro do lado do cliente durante toda a janela e confirma que o `ReplicaSet` recria o pod.

## Por quê

`gitops/app/hpa.yaml` fixa `minReplicas: 2` e `gitops/app/pdb.yaml` garante `minAvailable: 1`. Esses objetos existirem não prova que a perda de um pod é absorvida sem impacto perceptível — só um teste real prova (`docs/engineering-standards.md` §11).

## Como

```bash
AWS_PROFILE=cloudlab ./chaos/kill-api-pod.sh
```

Variáveis de ambiente opcionais:
- `TRAFFIC_WINDOW_SECONDS` (default 90) — duração total da janela de tráfego.
- `KILL_AFTER_SECONDS` (default 15) — quando, dentro da janela, o pod é morto.
- `MAX_ERROR_RATE_PERCENT` (default 1) — limiar de PASS/FAIL.

Nada precisa ser revertido no cluster ao final — o Kubernetes recria o pod deletado sozinho, isso *é* o comportamento sob teste. O script só limpa o `port-forward` local e arquivos temporários (`trap cleanup EXIT`).

## Como ler o resultado

- **PASS:** taxa de erro do cliente ficou dentro do limiar — a perda de um pod não foi visível para quem consome a API.
- **FAIL:** taxa de erro acima do limiar. Investigar:
  - `kubectl -n minitube-app get hpa api` — a réplica substituta demorou para ficar `Ready`? (`readinessProbe` em `gitops/app/deployment.yaml`, `initialDelaySeconds: 5`/`periodSeconds: 10`)
  - `kubectl -n minitube-app describe pdb api` — o PDB bloqueou alguma disrupção concorrente?
  - Se `ready_replicas < 2` no pré-check, o script falha antes de começar — a Deployment precisa estar com o HPA já estabilizado em pelo menos 2 réplicas.

## Resultado da execução (2026-07-26) — PASS

Executado contra a infra real (2 réplicas prontas, HPA em `cpu: 3%/70%`). Pod `api-7b868f7f45-kmvv6` deletado aos 15s da janela; o `ReplicaSet` criou `api-7b868f7f45-m6zlg` em seguida.

- **Total de requisições:** 94 (janela de 90s, uma a cada 0,5s).
- **Não-200:** 0.
- **Taxa de erro:** 0%.

`PASS`: `minReplicas: 2` + o `PodDisruptionBudget` absorveram a perda do pod sem nenhum impacto perceptível do lado do cliente — exatamente o comportamento esperado.
