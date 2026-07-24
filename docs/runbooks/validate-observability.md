# Runbook — Validação funcional da stack de observabilidade (Fase 5)

> Estabelece o padrão de "validação funcional pós-apply" descrito em [`docs/engineering-standards.md`](../engineering-standards.md#11-validação-funcional-pós-apply). Ver também [`docs/adr/011-observability-stack.md`](../adr/011-observability-stack.md).

## Por que isso existe

As 4 novas `Application`s do ArgoCD (`ebs-csi-driver`, `kube-prometheus-stack`, `loki`, `promtail`) reportando `Synced`/`Healthy` provam que os charts foram instalados — não provam que a stack funciona de ponta a ponta. As perguntas que importam: o EBS CSI driver provisionou volumes reais (PVCs `Bound`, não `Pending` para sempre)? O Prometheus tem alvos de scrape de verdade, incluindo a própria API (instrumentada nesta fase)? O Grafana está acessível publicamente com TLS válido? O Loki recebe logs reais, ou só está de pé sem nada chegando?

Este runbook documenta `terraform/envs/lab/scripts/validate-observability.sh`, que confirma cada uma dessas perguntas com uma prova funcional, não uma leitura de `describe-*`/`Synced`.

## Pré-requisitos

VPC + EKS + ArgoCD + CloudFront/DNS/TLS já validados (ver [`validate-eks-cluster.md`](./validate-eks-cluster.md), [`validate-argocd-gitops.md`](./validate-argocd-gitops.md) e [`validate-cloudfront-dns-tls.md`](./validate-cloudfront-dns-tls.md)) — a stack de observabilidade é só mais um conjunto de `Application`s no mesmo `terraform apply` de `envs/lab`, nada muda no fluxo de setup anterior.

Dependências no seu ambiente: `aws` CLI, `jq`, `terraform`, `kubectl`, `curl`, `dig`.

## Aplicar e rodar o teste

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform validate
AWS_PROFILE=cloudlab terraform plan     # revisar: node group 2->3, 2 novas IRSA roles, 4 novas Applications, 2 novos outputs
AWS_PROFILE=cloudlab terraform apply

AWS_PROFILE=cloudlab ./scripts/validate-observability.sh
```

⚠️ **Se `kube-prometheus-stack` ficar oscilando entre `Progressing`/`Degraded` (nunca `Healthy`), com os CRs `Prometheus`/`Alertmanager` existindo mas sem `StatefulSet` real criado** (ver [ADR 011, decisão 11](../adr/011-observability-stack.md)): o operator do Prometheus só descobre quais CRDs existem **na inicialização** do pod. Se ele tiver subido antes das CRDs (comum em `apply`s com retries/troubleshooting ao vivo, não esperado num `apply` limpo do zero), ele nunca vai reconhecer `Prometheus`/`Alertmanager` sozinho — precisa reiniciar:

```bash
kubectl -n minitube-platform rollout restart deployment/kube-prometheus-stack-operator
```

Os `StatefulSet`s devem aparecer em segundos depois disso.

⚠️ **Dê tempo ao ArgoCD antes de rodar o script.** As 4 novas `Application`s (em especial `kube-prometheus-stack`, que traz CRDs do Prometheus Operator) podem levar alguns minutos para sincronizar e ficarem `Healthy` depois do primeiro `apply` num ambiente novo — se o script falhar na primeira checagem (PVCs `Bound`), confira `kubectl -n argocd get applications` antes de assumir um bug real.

## Como acessar a UI do Grafana

```bash
# via Ingress público (mesmo padrão do ArgoCD, ADR 008)
open "https://grafana.minitube.projetodevops.com.br"
```

Usuário `admin`, senha gerada uma vez por sessão pelo Terraform (regenerada só quando `envs/lab` é recriado do zero, **não** a cada sync do ArgoCD):

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform output -raw grafana_admin_password; echo
```

⚠️ **Não use `kubectl get secret kube-prometheus-stack-grafana` para isso** (ver [ADR 011, decisão 12](../adr/011-observability-stack.md)) — o chart gera essa senha via `randAlphaNum` sempre que o Helm renderiza o template, e como o ArgoCD renderiza via `helm template` sem estado a cada sync (não um `helm upgrade` de verdade), cada sync gravava um valor novo no Secret enquanto o pod do Grafana já em execução continuava com a senha antiga em memória — os dois valores divergiam silenciosamente. A senha agora é gerada uma única vez em estado real do Terraform e injetada via `helm.parameters`, o que faz o Secret também ficar estável — mas a fonte de verdade é o `terraform output`, não o Secret.

## Como funciona o script de validação

- **Kubeconfig efêmero**: gerado via `aws eks update-kubeconfig` num arquivo temporário, sem escrever no `~/.kube/config` do operador.
- **Checagens executadas:**
  1. Todas as PVCs em `minitube-platform` atingem `Bound` (até 300s) — a prova de que o EBS CSI driver (novo nesta fase) provisionou volumes EBS reais, não só que a `StorageClass` existe como objeto.
  2. Prometheus (via port-forward) reporta zero alvos de scrape `down` — pega tanto uma configuração quebrada quanto um `kubeScheduler`/`kubeControllerManager`/`kubeEtcd: true` esquecido (inválido em EKS, control plane gerenciado pela AWS).
  3. `up{job="api"} == 1` no Prometheus — prova de que a instrumentação `/metrics` da API (`app/api/main.py`) e o `ServiceMonitor` dedicado (`gitops/plataforma/kube-prometheus-stack/servicemonitor-api.yaml`) funcionam de ponta a ponta.
  4. Grafana responde `200` em `https://grafana.<domínio>/login` — Ingress, DNS (external-dns) e TLS (certificado ACM wildcard) funcionando juntos.
  5. **Checagem central — ingestão real de logs:** o script gera tráfego real contra `/api/healthz`, depois faz *poll* no Loki (via port-forward, sem passar pelo Grafana) até uma consulta LogQL por `{namespace="minitube-app"}` retornar linhas — a prova de que o promtail está de fato lendo e enviando os logs dos containers, não só que o pod do Loki está `Running`.
- **Cleanup garantido:** `trap cleanup EXIT` mata todos os `port-forward`s abertos (Prometheus, Grafana não usa port-forward — vai direto via Ingress —, Loki, API); nada aqui gera drift no cluster, nenhuma reversão é necessária.

## Leitura esperada do output

```
PASS: All PVCs in minitube-platform reach Bound (up to 300s)
PASS: Prometheus reports zero down scrape targets
PASS: Prometheus scrapes app/api's /metrics (up{job="api"} == 1)
PASS: Grafana UI reachable via https://grafana.minitube.projetodevops.com.br
  [  10s] still waiting: log ingestion into Loki
  [  20s] still waiting: log ingestion into Loki
PASS: Loki has log lines for namespace=minitube-app (up to 180s, promtail shipping real logs)
=== All checks passed: PVCs bound via the EBS CSI driver, Prometheus scrapes real targets including the instrumented API, Grafana is reachable, and Loki holds real logs shipped by promtail. ===
```

Código de saída `0` quando tudo passa, `1` se qualquer checagem falhar.

## Confirmação visual do critério de conclusão da Fase 5

O script prova que a stack *funciona*; o critério de conclusão da fase (`CLAUDE.md`) exige um dashboard mostrando 4 sinais específicos — confirmar manualmente no Grafana após o script passar:

1. **Hit ratio do CDN** — datasource CloudWatch, namespace `AWS/CloudFront`, métricas `Requests`/`BytesDownloaded` (ou o dashboard oficial de CloudFront, se importado).
2. **Latência p95/p99 da API** — datasource Prometheus, `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{handler=~"/api.*"}[5m])) by (le))`.
3. **Saturação** — datasource Prometheus, métricas de `node-exporter` (CPU/memória por nó).
4. **Erros** — datasource CloudWatch, namespace `AWS/ApplicationELB`, métrica `HTTPCode_Target_5XX_Count`.

## Destruir tudo ao final do teste

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan -destroy   # revisar: remove a stack de observabilidade junto com VPC/EKS/S3/IRSA/ArgoCD/CloudFront -- tudo
AWS_PROFILE=cloudlab terraform destroy
```

⚠️ **Risco conhecido, ainda não confirmado nem descartado** (ver [ADR 011, decisão 4](../adr/011-observability-stack.md)): as `Application`s `kube-prometheus-stack` e `loki` (donas de PVC) ganharam o mesmo finalizer e proteção de `depends_on` já usados para o órfão da ALB do LBC (ADR 010), mas não há garantia de ordem entre `Application`s-irmãs dentro do mesmo `helm_release` — um volume EBS pode, em teoria, ficar órfão se o pod do `ebs-csi-driver` for removido antes da poda de PVC terminar. Depois do `destroy`, confirme:

```bash
aws ec2 describe-volumes --profile cloudlab --region us-east-1 \
  --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=*" \
  --query "Volumes[].{Id:VolumeId,State:State}"
```

Se algum volume aparecer com `State: available` (não anexado, não deletado), é o órfão previsto — apagar manualmente (`aws ec2 delete-volume --volume-id <id>`) e registrar a ocorrência real num ADR 012, seguindo o mesmo padrão de causa-raiz do ADR 010.

`terraform/bootstrap/` (ECR, Route 53, ACM, SSM) e `terraform/bootstrap-iam/` (roles, permission set, budget alert) **não** são destruídos — persistem entre sessões, sem custo relevante. Confirmar que não sobrou nada cobrável:

```bash
aws eks list-clusters --profile cloudlab --region us-east-1
aws ec2 describe-vpcs --profile cloudlab --region us-east-1 --filters "Name=tag:Name,Values=minitube-lab"
aws ec2 describe-nat-gateways --profile cloudlab --region us-east-1 --filter "Name=state,Values=available"
aws elbv2 describe-load-balancers --profile cloudlab --region us-east-1 --names minitube-app 2>&1 | grep -q "LoadBalancerNotFound" && echo "ALB: ausente (esperado)"
```
