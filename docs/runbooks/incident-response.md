# Runbook — Resposta a incidente na API do MiniTube

**Última atualização:** 2026-07-26
**Ambiente:** `terraform/envs/lab` (EKS efêmero, recriado por sessão)
**Tempo estimado:** 10-30 minutos, dependendo da causa
**Nível de risco:** Baixo a médio (leitura/triagem; qualquer mitigação permanente é só um commit em `gitops/`, nunca `kubectl apply`/`edit` manual)

---

## Objetivo

Guia geral de como detectar, triar e mitigar um incidente na API/HLS do MiniTube — não um procedimento único, e sim o ponto de entrada que direciona para o runbook certo dependendo do sintoma. Complementa (não repete) os runbooks de validação (`docs/runbooks/validate-*.md`) e os três experimentos de caos já treinados (`docs/runbooks/chaos-*.md`), que documentam o comportamento *esperado* do sistema sob cada tipo de falha.

---

## Pré-requisitos

- [ ] `AWS_PROFILE=cloudlab` configurado e `aws sts get-caller-identity` retornando a identidade correta.
- [ ] `terraform/envs/lab` aplicado (cluster de pé) — sem isso não há o que triar.
- [ ] `kubectl`, `curl`, `jq` no `PATH`.
- [ ] Acesso ao Grafana (`https://grafana.<domínio>` — senha via `terraform output -raw grafana_admin_password` em `terraform/envs/lab`, ver [`docs/runbooks/access-argocd-ui.md`](access-argocd-ui.md) para o padrão equivalente do ArgoCD).

---

## ⚠️ Pontos de Atenção

- **Nunca `kubectl apply`/`edit`/`patch` permanente em nada gerenciado pelo ArgoCD.** Qualquer mitigação que precise sobreviver ao próximo sync tem que virar commit em `gitops/`. Uma mudança manual não commitada é revertida pelo `selfHeal` em segundos, e mascara o sintoma real.
- **`kubectl scale`/`cordon`/`drain`/`delete pod` são operações de runtime aceitáveis** mesmo sob GitOps — não alteram o estado declarado, só o estado de runtime (mesmo raciocínio dos 3 scripts em `chaos/`). Usadas para mitigação temporária ou para reproduzir um cenário de teste, não para consertar a causa raiz.
- **Nunca gere um kubeconfig persistente.** Sempre `aws eks update-kubeconfig --kubeconfig <arquivo temporário>` — mesmo padrão de todo script deste repositório (`scripts/validate-*.sh`, `chaos/*.sh`).
- **`terraform/envs/lab` é efêmero.** Se o incidente for causado por drift de infraestrutura (não de aplicação), considere se vale mais a pena investigar a causa raiz no código Terraform do que caçar o sintoma no ambiente atual, que será destruído ao final da sessão de qualquer forma.

---

## Passos

### 1. Detectar

Dois sinais oficiais, ambos definidos em [`gitops/plataforma/kube-prometheus-stack/slo-rules.yaml`](../../gitops/plataforma/kube-prometheus-stack/slo-rules.yaml) (`PrometheusRule minitube-api-slo`):

```bash
# Gera kubeconfig efêmero (repita em qualquer passo abaixo que precise dele)
kubeconfig=$(mktemp)
aws eks update-kubeconfig --region us-east-1 \
  --name "$(terraform -chdir=terraform/envs/lab output -raw eks_cluster_name)" \
  --kubeconfig "$kubeconfig"

# Alertas ativos no momento
kubectl --kubeconfig "$kubeconfig" -n minitube-platform port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s http://127.0.0.1:9090/api/v1/alerts | jq '.data.alerts[] | select(.state=="firing")'
```

| Alerta | Significa | Severidade |
| --- | --- | --- |
| `APIAvailabilitySLOBreach` | Menos de 1 réplica `api` disponível por mais de 5 minutos | `critical` |
| `APILatencySLOBreach` | p95 de `/api*` acima do limiar definido em `slo-rules.yaml` por mais de 5 minutos | `warning` |

Complementar visualmente: dashboard "dia do jogo" em `https://grafana.<domínio>` (hit ratio do CDN, latência p95/p99, saturação de nó, erros da ALB — os 4 sinais do critério de conclusão da Fase 5).

**Resultado esperado:** um alerta identificado (ou ausência de qualquer alerta — nesse caso, o sintoma relatado pode ser algo fora do escopo do SLO atual, ex.: erro percebido pelo usuário sem refletir nas métricas monitoradas).

---

### 2. Triar

**Estado da aplicação:**

```bash
kubectl --kubeconfig "$kubeconfig" -n minitube-app get pods -o wide
kubectl --kubeconfig "$kubeconfig" -n minitube-app get hpa api
kubectl --kubeconfig "$kubeconfig" -n minitube-app describe deployment api
```

**Logs (Loki, via `port-forward`, sem depender do Grafana estar acessível):**

```bash
kubectl --kubeconfig "$kubeconfig" -n minitube-platform port-forward svc/loki 3100:3100 &
curl -sf http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="minitube-app"} |= "ERROR"' \
  --data-urlencode "start=$(( $(date +%s) - 900 ))000000000" | jq
```

**Métricas (Prometheus, mesmo `port-forward` do passo 1):**

```bash
# p95 de latência atual por handler
curl -s http://127.0.0.1:9090/api/v1/query --data-urlencode \
  'query=histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{handler=~"/api.*"}[5m])) by (le, handler))' | jq
```

**Resultado esperado:** uma hipótese de causa raiz — pod específico com erro, saturação de CPU, node com problema, ou algo fora da aplicação (DNS, cert, ALB).

---

### 3. Agir / mitigar

A tabela de Troubleshooting abaixo mapeia sintoma → cenário já treinado. Se o sintoma bate com um dos três experimentos de caos, o comportamento *esperado* do sistema (e o que checar se ele não se comportar assim) já está documentado no runbook correspondente — não repita a investigação do zero.

**Mitigação imediata (runtime, não commitada) vs. correção definitiva (commit em `gitops/`):** se a ação para estabilizar o sistema for algo como `kubectl delete pod` (deixa o ReplicaSet recriar) ou `kubectl scale --replicas=N` temporário, isso é aceitável como paliativo. Mas se o incidente reaparecer, a correção real (um limite de recursos, um valor de HPA, uma probe) precisa virar commit — nunca deixar uma mudança manual como solução permanente.

---

## Validação pós-mitigação

```bash
# Alertas voltaram a não estar firing
curl -s http://127.0.0.1:9090/api/v1/alerts | jq '.data.alerts[] | select(.state=="firing")'

# Aplicação saudável
kubectl --kubeconfig "$kubeconfig" -n minitube-app get pods
curl -sf "$(terraform -chdir=terraform/envs/lab output -raw app_url)/api/healthz"
```

**Critério de sucesso:**
- [ ] Nenhum alerta `firing` em `APIAvailabilitySLOBreach`/`APILatencySLOBreach`.
- [ ] Todos os pods `api` em `Running`/`Ready`.
- [ ] `/api/healthz` responde `200` através do CloudFront (não só via `port-forward`).
- [ ] Se a mitigação exigiu uma mudança permanente: commit aberto/mergeado em `gitops/`, `kubectl -n argocd get applications` de volta a `Synced`/`Healthy`.

---

## Troubleshooting

| Sintoma | Causa provável | Ação |
| --- | --- | --- |
| `APIAvailabilitySLOBreach` disparado, poucos pods `Running` | Perda de um ou mais pods da API (deploy, OOM, node) | Comparar com [`docs/runbooks/chaos-kill-api-pod.md`](chaos-kill-api-pod.md) — se a recuperação não seguiu o padrão esperado (nova réplica `Ready` em segundos), investigar `kubectl describe pod`/eventos |
| Pods `Pending` em massa, nodes com pouca capacidade | Perda de um node spot, ou HPA escalando além da capacidade dos nodes restantes | Comparar com [`docs/runbooks/chaos-drain-spot-node.md`](chaos-drain-spot-node.md) — checar `kubectl get nodes`, se `desired_size` (Terraform) bate com o número real de nodes `Ready` |
| `APILatencySLOBreach` disparado, réplicas todas `Ready` | Saturação de CPU sob carga (o HPA ainda não escalou o suficiente, ou o teto real de capacidade foi atingido) | Ver [`docs/runbooks/run-k6-breakpoint.md`](run-k6-breakpoint.md) para o teto de capacidade conhecido; `kubectl top pods -n minitube-app` |
| Dashboards/alertas não aparecem, mas a aplicação responde normalmente | Stack de observabilidade fora do ar (não é, por si, uma indisponibilidade da aplicação) | Comparar com [`docs/runbooks/chaos-disable-observability-stack.md`](chaos-disable-observability-stack.md) — confirmar que o impacto está mesmo contido à telemetria, não à aplicação |
| `Application` do ArgoCD em `OutOfSync`/`Degraded` | Erro de sync (CRD grande demais, webhook, etc.) | `kubectl -n argocd get application <nome> -o yaml`, ver `status.conditions` — classes de bug já catalogadas nos ADRs 007-011 |
| `/api/*` responde 502/404 só via CloudFront, mas funciona via `port-forward` | Problema de roteamento de borda (ALB, CloudFront origin, DNS) — não é um bug de aplicação | Ver ADR 009 (decisões 3-4) para a classe de bug já resolvida uma vez nesta arquitetura |

---

## Referências

- [`gitops/plataforma/kube-prometheus-stack/slo-rules.yaml`](../../gitops/plataforma/kube-prometheus-stack/slo-rules.yaml) — definição dos dois alertas.
- [`docs/runbooks/chaos-kill-api-pod.md`](chaos-kill-api-pod.md), [`chaos-drain-spot-node.md`](chaos-drain-spot-node.md), [`chaos-disable-observability-stack.md`](chaos-disable-observability-stack.md) — cenários treinados.
- [`docs/runbooks/run-k6-breakpoint.md`](run-k6-breakpoint.md), [`run-k6-waves.md`](run-k6-waves.md) — comportamento sob carga.
- [`docs/runbooks/validate-observability.md`](validate-observability.md) — como validar a stack de observabilidade do zero.
- [`docs/adr/012-hpa-cpu-autoscaling.md`](../adr/012-hpa-cpu-autoscaling.md) — dimensionamento do HPA.
- ADRs 007-011 — catálogo de bugs reais já encontrados nesta arquitetura (ArgoCD, roteamento de borda, observabilidade).
