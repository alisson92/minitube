# Chaos: derrubar a stack de observabilidade

## O quê

`chaos/disable-observability-stack.sh` pausa temporariamente o `selfHeal` das Applications ArgoCD `kube-prometheus-stack` e `loki` (só essas duas — `aws-load-balancer-controller`, `external-dns`, `cert-manager` e o `ebs-csi-driver` vivem no mesmo namespace `minitube-platform`, mas não são tocados), escala Prometheus/Alertmanager/Grafana/Loki a zero réplicas, e gera tráfego real contra a API e a playlist HLS (via CloudFront) para confirmar que a aplicação continua servindo normalmente sem nenhuma telemetria de pé.

## Por quê

Confirma blast radius contido: uma falha na stack de observabilidade não pode ser, ela mesma, um incidente de disponibilidade da aplicação.

## Como

```bash
AWS_PROFILE=cloudlab ./chaos/disable-observability-stack.sh
```

Variáveis de ambiente opcionais:
- `TRAFFIC_WINDOW_SECONDS` (default 60)
- `MAX_ERROR_RATE_PERCENT` (default 0 — a expectativa aqui é impacto zero, não "aceitável")

**Sobre pausar `selfHeal` via `kubectl patch`:** essa técnica já foi usada (e registrada na seção "Estado atual" do `CLAUDE.md`) durante troubleshooting manual de `terraform destroy` em sessões anteriores. Este script a formaliza como procedimento versionado e sempre revertido — nunca uma mudança permanente fora do Git. O `trap cleanup EXIT` restaura, na ordem inversa, primeiro as réplicas originais (capturadas antes de qualquer mutação) e só depois o `syncPolicy` original de cada Application, para que o ArgoCD não entre em sync no meio da restauração das réplicas.

**Descoberta de recursos:** o script encontra os Deployments/StatefulSets a escalar via o label `app.kubernetes.io/instance in (kube-prometheus-stack, loki)` — o nome do release Helm que o ArgoCD usa por padrão é o próprio nome da Application (nenhum `releaseName` é sobrescrito em `terraform/envs/lab/argocd.tf`). Se a descoberta retornar vazio, o script falha com uma mensagem indicando como inspecionar os labels manualmente.

## Como ler o resultado

- **PASS:** taxa de erro 0% (ou dentro do limiar configurado) durante toda a janela — a API e o HLS seguiram servindo tráfego sem nenhuma dependência real da stack de observabilidade em runtime.
- **FAIL:** algo na aplicação depende da stack de observabilidade estar de pé — investigar se algum `initContainer`/sidecar/health check da API consulta Prometheus/Loki diretamente (não deveria).
- Ao final, confira que a stack voltou: `kubectl -n minitube-platform get pods -l 'app.kubernetes.io/instance in (kube-prometheus-stack,loki)'` — todos `Running`, e `kubectl -n argocd get applications kube-prometheus-stack loki` de volta a `Synced`/`Healthy` (o `selfHeal` reconcilia sozinho depois do `syncPolicy` restaurado).

## Resultado da execução (2026-07-26) — bug real encontrado e corrigido, resultado ainda pendente

Primeira execução real: pausou o `selfHeal` das duas Applications, descobriu e escalou os 5 workloads corretos a zero (`kube-prometheus-stack-grafana`, `-kube-state-metrics`, `-operator`, `-operator-webhook`, `statefulset/loki`), confirmou os `node-exporter` (DaemonSet, fora do escopo) seguindo `Running` normalmente — e então **abortou silenciosamente** logo depois de abrir o `port-forward` para a API, pulando toda a geração de tráfego e a seção de resultado. O `trap cleanup EXIT` disparou e restaurou tudo corretamente (réplicas e `syncPolicy` de volta ao original) — a parte de limpeza funcionou; a parte de medição, não.

**Causa raiz:** o script tentava descobrir um `video_id` com `curl -sf GET /api/videos` (esperando uma lista JSON) — mas `app/api/main.py` só expõe `POST /api/videos` (upload) e `GET /api/videos/{video_id}`, nunca uma rota de listagem. O `GET` batia `405 Method Not Allowed`, `curl -sf` retornava não-zero, e sob `set -euo pipefail` o script abortava naquele ponto exato, sem nenhuma mensagem de erro visível (a falha ficou dentro de uma substituição de comando).

**Corrigido:** o script agora reaproveita `load/lib/find-or-create-video.sh` (a mesma lib usada por `run-breakpoint-from-ec2.sh`/`run-waves-from-ec2.sh`), que acha um vídeo já transcodificado direto no S3 — sem depender de nenhuma rota de listagem que nunca existiu.

**Ainda não revalidado** — a correção não foi reexecutada contra o cluster real nesta sessão. Próximo passo: rodar de novo (`AWS_PROFILE=cloudlab ./chaos/disable-observability-stack.sh`) para obter o resultado real de taxa de erro.
