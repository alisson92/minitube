# Runbook: baseline de carga k6 (Fase 6)

## O quê

`load/run-baseline.sh` roda o **primeiro** teste de carga da Fase 6 (`load/k6/baseline.js`) contra o ambiente **exatamente como ele está hoje**: API com 1 réplica fixa (`gitops/app/deployment.yaml`), node group do EKS fixo em 3/3/3 (`terraform/envs/lab/variables.tf`), sem HPA e sem Cluster Autoscaler/Karpenter.

O script sobe uma carga pequena e crescente (k6 `ramping-vus`, ~9 minutos) em dois cenários paralelos, espelhando os dois fluxos da arquitetura descritos no `CLAUDE.md`:

- **`viewers`** — simula a "onda de torcida" de verdade: requisições repetidas para a playlist HLS e os segmentos de um vídeo já transcodificado, via CloudFront. A imensa maioria dessas requisições deve morrer no CDN.
- **`api_dynamic`** — um volume bem menor de tráfego dinâmico direto na API (`/api/healthz`, `/api/videos/{id}`) via ALB → EKS — a única réplica sem autoscaling ainda, candidata mais provável a saturar primeiro.

## Por quê

Este é deliberadamente o **primeiro** teste da fase, antes de qualquer mitigação (HPA, Cluster Autoscaler, ajuste do SLO de 500ms em `slo-rules.yaml`). Adicionar uma mitigação antes de ter dado real seria uma aposta, não uma decisão embasada — ver a seção "Sequência lógica" combinada com o operador nesta fase. O resultado deste script é o que decide:

1. Se o gargalo é de **pod** (CPU/memória do único réplica da API) ou de **node group** (capacidade do cluster) — determina se a resposta é HPA (barato) ou Cluster Autoscaler/Karpenter (mais caro).
2. Se o threshold de 500ms em `slo-rules.yaml` é realista, frouxo ou apertado demais — hoje é um valor arbitrário, o próprio arquivo já sinaliza isso.

Upload/transcodificação em massa **não** faz parte deste baseline — subir vários Jobs de transcodificação concorrentes é um cenário de estresse separado e mais pesado, não uma carga pequena/crescente.

## Como

```bash
AWS_PROFILE=cloudlab ./load/run-baseline.sh
```

Pré-requisitos: `k6`, `aws`, `jq`, `terraform`, `kubectl`, `curl`, `ffmpeg` no PATH; `terraform apply` já rodou em `terraform/envs/lab` e o ArgoCD já sincronizou `gitops/app/` (ver `docs/runbooks/validate-transcoding.md`).

O script:

1. Lê os outputs do Terraform (`app_url`, nome do bucket, nome do cluster).
2. Procura um vídeo já transcodificado no S3 (`hls/*/playlist.m3u8`); se não encontrar, sobe um vídeo sintético via `POST /api/videos` e espera o Job de transcodificação terminar — mesmo padrão já usado em `validate-transcoding.sh`/`validate-cloudfront-dns-tls.sh`.
3. Roda `k6 run load/k6/baseline.js` contra a URL pública (`app.<domínio>`), com o `video_id` encontrado/gerado.

## Como ler o resultado

O sumário do k6 ao final mostra, por `endpoint` (tag `playlist`, `segment`, `api`):

- **`http_req_failed`** — taxa de erro. O threshold configurado (`rate<0.01`) falha o `k6 run` (exit code ≠ 0) se mais de 1% das requisições falharem em qualquer cenário — esse é o sinal mais direto de "algo quebrou".
- **`http_req_duration` p95** — comparar contra os 500ms do `slo-rules.yaml`. Se `endpoint:api` estourar consistentemente antes de `endpoint:playlist`/`endpoint:segment`, é evidência de que o gargalo é o pod da API, não o CDN/origem — a favor de HPA como primeira mitigação.
- Cruzar o horário do teste com os dashboards da Fase 5 no Grafana (saturação de CPU/memória do pod `api`, saturação dos nós) para confirmar se o gargalo foi de pod ou de node group antes de decidir a mitigação.

Este teste **não se autolimpa como os `validate-*.sh`** no sentido de destruir infraestrutura — ele só lê/gera tráfego HTTP e, na ausência de vídeo existente, cria um vídeo de teste real no S3 (que passa a contar como "vídeo já transcodificado" nas execuções seguintes). Nenhum recurso do Terraform é criado ou destruído por este script.

## Resultado validado (2026-07-24)

Rodado contra a infra real (1 réplica da API, node group 3/3/3, sem HPA): **0% de erro** em 8733 requisições, thresholds todos verdes com folga confortável — p95 de 186ms (`api`), 120ms (`playlist`) e 184ms (`segment`), todos bem abaixo dos 500ms do `slo-rules.yaml`. Pico de carga: só 60 VUs (50 `viewers` + 10 `api_dynamic`), ~20 req/s no total.

**Isso não significa que a arquitetura não quebra sob carga — significa que este baseline é pequeno demais para descobrir onde.** A API roda `uvicorn` sem `--workers` (`app/api/Dockerfile`) — um único processo, sob limite de `500m` de CPU — mas o cenário `api_dynamic` nunca gerou volume suficiente para chegar perto desse teto (10 VUs com 2-5s de sleep entre iterações = poucas requisições/segundo reais contra o pod). `viewers` bate em CloudFront/S3, que não tem motivo pra sentir 50 VUs. Baseline **confirmado estável sob carga leve**; permanece registrado como está, sem escalar — para achar o ponto real de quebra, use `docs/runbooks/run-k6-breakpoint.md`.
