# Chaos: simular interrupção de node spot

## O quê

`chaos/drain-spot-node.sh` escolhe um node do node group `minitube-spot`, faz `kubectl cordon` + `kubectl drain --ignore-daemonsets --delete-emptydir-data`, e confirma que o Deployment `api` volta a `Ready` nos nodes restantes dentro de um timeout. Não termina a instância EC2 de verdade — isso entraria em conflito com o `desired_size` fixo do ASG (`3/3/3`, ver ADR 011) e arriscaria drift de state do Terraform; cordon+drain simula o efeito relevante (perda de capacidade de um node) sem esse risco.

Por padrão, evita nodes que hospedam pods com PVC (`minitube-platform` — Prometheus, Loki, Grafana): um volume EBS é preso à AZ, então drenar esse node faria o pod ficar `Pending` por um motivo de storage, não pela perda de node em si, que é o que este experimento quer exercitar.

## Por quê

O node group é spot — interrupções reais acontecem. O objetivo é confirmar que o cluster reagenda a carga sem intervenção manual antes que isso aconteça de verdade em produção.

## Como

```bash
AWS_PROFILE=cloudlab ./chaos/drain-spot-node.sh
```

Variáveis de ambiente opcionais:
- `DRAIN_TIMEOUT_SECONDS` (default 120)
- `RESCHEDULE_TIMEOUT_SECONDS` (default 120)

O node escolhido é sempre descordonado ao final (`trap cleanup EXIT`), mesmo em caso de falha — nunca deve sobrar um node marcado `SchedulingDisabled` depois de rodar este script.

## Como ler o resultado

- **PASS:** `kubectl rollout status deployment/api` reportou `Ready` dentro do timeout — os pods da API reagendaram para os nodes restantes sem intervenção.
- **FAIL:**
  - Confira `kubectl -n minitube-app get pods -o wide` — os pods ficaram `Pending`? Provavelmente falta de capacidade nos nodes restantes (2 nodes × 17 pods/nó via VPC CNI, ver ADR 011 decisão 1) — nesse caso o `maxReplicas: 6` do HPA pode estar tentando escalar além do que 2 nodes comportam.
  - Se o script falhou porque **todos** os nodes hospedam pods com PVC, é sinal de que o cluster está rodando com menos nodes do que o esperado (`3/3/3`) — confira `kubectl get nodes`.

## Resultado da execução (`<preencher após rodar>`)

_Aguardando primeira execução real contra o cluster — ver [`docs/runbooks/incident-response.md`](incident-response.md) para o contexto mais amplo de resposta a incidente._
