# gitops/plataforma

Este diretório é sincronizado continuamente pelo ArgoCD através da Application
raiz `platform` (declarada em `terraform/envs/lab/argocd.tf`, chart
`argocd-apps`), no `AppProject minitube-platform`.

## Por que está vazio nesta fase

A Fase 3 (GitOps) cria a Application raiz que aponta para este diretório
antes de haver qualquer componente de plataforma real para sincronizar — ela
reconcilia "0 recursos" (status `Synced`, sem `Healthy` por não haver
workload nenhum), o que é esperado e não é uma falha. A vantagem de já
existir agora: a partir da Fase 5, adicionar `kube-prometheus-stack` e Loki
aqui é só um commit em `gitops/`, sem precisar tocar Terraform de novo.

## O que chega em fases futuras

- **Fase 5 — Observabilidade:** `kube-prometheus-stack` (Prometheus +
  Grafana + Alertmanager) e Loki, provavelmente como manifests que apontam
  para os charts oficiais via a própria Application (source `helm`), ou como
  subdiretórios Kustomize — decisão a registrar em ADR quando a fase chegar.
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
