# MiniTube 📺

Uma mini plataforma de streaming de vídeo construída de ponta a ponta como projeto de estudo em **DevOps e SRE** — inspirada na pergunta: *"como o YouTube aguentou o recorde de público das lives da CazéTV na Copa do Mundo?"*

A resposta curta: cache na borda, camadas que filtram tráfego e uma origem que escala horizontalmente. Este projeto reproduz essa arquitetura em miniatura na AWS e a submete ao seu próprio "dia do jogo" com testes de carga. A história completa está em [`docs/000-motivation.md`](docs/000-motivation.md).

## Stack

| Camada | Tecnologia |
| ------ | ---------- |
| Infraestrutura como código | Terraform (backend remoto em S3) |
| Orquestração | Kubernetes (EKS, node group spot) |
| Borda / CDN | CloudFront servindo segmentos HLS a partir do S3 |
| Vídeo | FFmpeg (transcodificação → HLS) |
| GitOps | ArgoCD + Kustomize/Helm |
| DNS e TLS | Route 53, external-dns, cert-manager (domínio próprio) |
| Observabilidade | Prometheus, Grafana, Loki, SLOs |
| Testes de carga | k6 (ondas simulando a torcida) |

## Princípio central: infraestrutura efêmera

O ambiente sobe (`terraform apply`), é testado e observado, e **é destruído ao final de cada sessão** (`terraform destroy`) — o EKS cobra pelo control plane mesmo ocioso. Recriar tudo do zero deve ser indolor: esse é o teste de qualidade do código.

## Estrutura

```
terraform/
  bootstrap/       # bucket S3 de state (versionado, criptografado, lock nativo); repositórios ECR
  bootstrap-iam/   # usuário operacional cloudlab-operator (admin-only, via CloudShell)
  envs/lab/        # VPC, EKS, S3 de vídeo, IAM da app, CloudFront, DNS
gitops/      # manifests da app e da plataforma (Kustomize), reconciliados pelo ArgoCD
app/         # API (FastAPI) e transcoder (FFmpeg) + Dockerfiles
load/        # cenários k6
docs/        # motivação, ADRs, runbooks e retrospectos por fase
```

## Como começar

O bootstrap de uma conta AWS nova (conta dedicada, usuário operacional via Terraform, backend remoto de state) está documentado passo a passo em [`docs/runbooks/aws-account-bootstrap.md`](docs/runbooks/aws-account-bootstrap.md).

## Status

🚧 **Fase 5 — Observabilidade, prestes a começar.** Fases 1–4 encerradas: backend remoto, VPC, EKS com node group spot e budget alert ([`docs/phases/001-terraform-foundation.md`](docs/phases/001-terraform-foundation.md)); API (FastAPI) + transcoder (FFmpeg) como Job no EKS, gravando HLS no S3 ([`docs/phases/002-application.md`](docs/phases/002-application.md)); ArgoCD instalado via Terraform, `gitops/app/` e `gitops/platform/` reconciliados a partir do Git, sem nenhum `kubectl apply` manual ([`docs/phases/003-gitops.md`](docs/phases/003-gitops.md)); CloudFront + Route 53 + cert-manager servindo `app.<domínio>` com HTTPS válido ([ADR 008](docs/adr/008-cloudfront-dns-tls.md); retrospecto formal da fase ainda pendente em `docs/phases/`). O roteiro completo das fases, as convenções e o estado vivo do projeto estão em [`CLAUDE.md`](CLAUDE.md).
