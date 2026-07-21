# gitops/plataforma

Este diretório é sincronizado continuamente pelo ArgoCD através da Application
raiz `platform` (declarada em `terraform/envs/lab/argocd.tf`, chart
`argocd-apps`), no `AppProject minitube-platform`. A partir da Fase 4, também
hospeda os `values.yaml` estáticos consumidos por 3 Applications dedicadas
(uma por add-on), declaradas na mesma `argocd.tf`.

## Conteúdo (Fase 4 — Borda, DNS e TLS)

- **`aws-load-balancer-controller/values.yaml`**, **`external-dns/values.yaml`**,
  **`cert-manager/values.yaml`** — values estáticos de cada add-on. Não são
  manifests Kubernetes válidos sozinhos (por isso a Application `platform`
  os exclui via `directory.exclude` em vez de tentar sincronizá-los como
  recursos) — são consumidos como um segundo `source` (`ref: values`) pelas
  3 Applications multi-source dedicadas a cada add-on.
- **`cert-manager/cluster-issuer.yaml`** — único manifest plano real desta
  fase, sincronizado normalmente pela Application `platform`.
- **`argocd/ingress.yaml`** — Ingress do `argocd-server`, compartilhando a
  mesma ALB do Ingress de `gitops/app/` (mesmo `IngressGroup`).

Decisões de arquitetura (multi-source Application vs. Kustomize `helmCharts`,
IngressGroup compartilhado, ClusterIssuer sem consumidor público ainda) em
[`docs/adr/008-cloudfront-dns-tls.md`](../../docs/adr/008-cloudfront-dns-tls.md).

## O que chega em fases futuras

- **Fase 5 — Observabilidade:** `kube-prometheus-stack` (Prometheus +
  Grafana + Alertmanager) e Loki, seguindo o mesmo padrão de subdiretório
  por componente já estabelecido nesta fase.
- **Candidato futuro, não decidido nem implementado:** migrar a própria
  instalação do ArgoCD para *self-management* (uma Application aqui gerenciando
  o Helm release do próprio ArgoCD, hoje feito via `helm_release` no
  Terraform). Avaliado e descartado por ora — ver alternativas consideradas
  em [`docs/adr/007-argocd-gitops-bootstrap.md`](../../docs/adr/007-argocd-gitops-bootstrap.md).

## AppProject

O `AppProject minitube-platform` (que restringe o destino e os recursos
cluster-scoped permitidos para o que for sincronizado a partir deste
diretório) é declarado via Terraform, não como um manifest aqui dentro — ver
o ADR 007 para a justificativa (evita o problema de ovo-e-galinha em que a
Application que sincroniza este path dependeria de um projeto que só
existiria depois do primeiro sync dela mesma).
