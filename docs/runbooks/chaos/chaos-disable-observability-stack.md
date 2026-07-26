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

**Descoberta de recursos:** o script escala tudo em `minitube-platform` **exceto** os add-ons de plataforma que não fazem parte deste experimento (`aws-load-balancer-controller`, `external-dns`, `cert-manager*`, `ebs-csi-controller`) — uma lista de exclusão, não de inclusão. A primeira versão usava inclusão via `app.kubernetes.io/instance in (kube-prometheus-stack, loki)`, que cobre os recursos templados direto pelo chart Helm (Grafana, kube-state-metrics, o operator e seu webhook, Loki) mas **não** o StatefulSet real do Prometheus/Alertmanager — esses são criados dinamicamente pelo Prometheus Operator a partir dos CRs `Prometheus`/`Alertmanager`, com um esquema de labels próprio do operator, não o label de instância do Helm. Ver "Resultado da execução" abaixo — esse gap só apareceu rodando de verdade.

## Como ler o resultado

- **PASS:** taxa de erro 0% (ou dentro do limiar configurado) durante toda a janela — a API e o HLS seguiram servindo tráfego sem nenhuma dependência real da stack de observabilidade em runtime.
- **FAIL:** algo na aplicação depende da stack de observabilidade estar de pé — investigar se algum `initContainer`/sidecar/health check da API consulta Prometheus/Loki diretamente (não deveria). **Antes de aceitar essa conclusão, confirme que o Prometheus/Alertmanager de verdade foram escalados a zero** (`kubectl -n minitube-platform get statefulset` — ambos devem aparecer na lista impressa em "Workloads to scale to zero") — um `FAIL` com esses dois ainda de pé não prova nada sobre blast radius, só que algo mais aconteceu durante a janela.
- Ao final, confira que a stack voltou: `kubectl -n minitube-platform get deploy,statefulset` — todos com as réplicas originais, e `kubectl -n argocd get applications kube-prometheus-stack loki` de volta a `Synced`/`Healthy` (o `selfHeal` reconcilia sozinho depois do `syncPolicy` restaurado).

## Resultado da execução (2026-07-26) — bug real encontrado e corrigido, resultado ainda pendente

Primeira execução real: pausou o `selfHeal` das duas Applications, descobriu e escalou os 5 workloads corretos a zero (`kube-prometheus-stack-grafana`, `-kube-state-metrics`, `-operator`, `-operator-webhook`, `statefulset/loki`), confirmou os `node-exporter` (DaemonSet, fora do escopo) seguindo `Running` normalmente — e então **abortou silenciosamente** logo depois de abrir o `port-forward` para a API, pulando toda a geração de tráfego e a seção de resultado. O `trap cleanup EXIT` disparou e restaurou tudo corretamente (réplicas e `syncPolicy` de volta ao original) — a parte de limpeza funcionou; a parte de medição, não.

**Causa raiz:** o script tentava descobrir um `video_id` com `curl -sf GET /api/videos` (esperando uma lista JSON) — mas `app/api/main.py` só expõe `POST /api/videos` (upload) e `GET /api/videos/{video_id}`, nunca uma rota de listagem. O `GET` batia `405 Method Not Allowed`, `curl -sf` retornava não-zero, e sob `set -euo pipefail` o script abortava naquele ponto exato, sem nenhuma mensagem de erro visível (a falha ficou dentro de uma substituição de comando).

**Corrigido:** o script agora reaproveita `load/lib/find-or-create-video.sh` (a mesma lib usada por `run-breakpoint-from-ec2.sh`/`run-waves-from-ec2.sh`), que acha um vídeo já transcodificado direto no S3 — sem depender de nenhuma rota de listagem que nunca existiu.

## Resultado da execução (2026-07-26, pós-fix #1) — segundo bug real: Prometheus/Alertmanager nunca foram derrubados

Reexecutado após o fix do `video_id`. Desta vez o script rodou até o fim e reportou `FAIL`: 6 de 32 requisições não-200 (`18,75%`) na janela de 60s.

**Antes de aceitar essa conclusão, confirmei a lista de workloads escalados nas duas execuções (a original e esta):** nunca incluiu o StatefulSet do Prometheus nem do Alertmanager — só `kube-prometheus-stack-grafana`, `-kube-state-metrics`, `-operator`, `-operator-webhook` e `statefulset/loki`. **O Prometheus (e o Alertmanager) ficaram de pé o tempo todo** — o experimento nunca testou o que se propõe a testar, então o `FAIL` de 18,75% não pode ser atribuído a "a app depende da stack de observabilidade" sem mais evidência.

**Causa raiz:** a descoberta original incluía por `app.kubernetes.io/instance` (label do Helm), que só cobre recursos templados diretamente pelo chart — o Prometheus Operator cria o StatefulSet real do Prometheus/Alertmanager dinamicamente a partir dos CRs, com labels próprios do operator, nunca vistos pela query original.

**Corrigido:** a descoberta agora exclui por nome os add-ons que não fazem parte do experimento (`aws-load-balancer-controller`, `external-dns`, `cert-manager*`, `ebs-csi-controller`) e escala **tudo o mais** em `minitube-platform` — cobre Prometheus/Alertmanager independente de como o operator os rotula. O "wait" e a checagem de estado pós-scale-down também foram trocados de um seletor de pods (mesmo problema) para polling direto de `.status.replicas` de cada workload descoberto.

## Resultado da execução (2026-07-26, pós-fix #2) — PASS real, com um efeito colateral corrigido

Reexecutado com a descoberta por exclusão. Desta vez `statefulset/prometheus-kube-prometheus-stack-prometheus` e `statefulset/alertmanager-kube-prometheus-stack-alertmanager` apareceram na lista e foram escalados a zero de verdade, junto com Grafana/kube-state-metrics/operator/operator-webhook/Loki.

- **Total de requisições (API + playlist HLS):** 60 (janela de 60s).
- **Não-200:** 0.
- **Taxa de erro:** 0%.

`PASS`: com o Prometheus e o Alertmanager realmente fora do ar (confirmado, não presumido), a API e o HLS seguiram servindo 100% do tráfego — blast radius contido, como o experimento se propõe a provar.

**Efeito colateral encontrado e corrigido:** a lista de exclusão original não incluía `metrics-server` (Application separada da Fase 6/ADR 012, usada só pelo HPA — não faz parte da stack de observabilidade). Ele foi varrido pela descoberta por engano, e como o script nunca pausou o `selfHeal` da Application dele (só de `kube-prometheus-stack`/`loki`), o ArgoCD reverteu o `scale --replicas=0` sozinho antes dos 90s de espera (`WARN: deployment/metrics-server still reports 1 replica(s) after 90s`) — inofensivo (ele nunca devia ter sido tocado mesmo, e nunca ficou fora do ar de verdade), mas fora do escopo do experimento. Adicionado à lista de exclusão.
