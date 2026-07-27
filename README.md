# MiniTube 📺

[![CI](https://github.com/alisson92/minitube/actions/workflows/ci.yml/badge.svg)](https://github.com/alisson92/minitube/actions/workflows/ci.yml)

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
  bootstrap-iam/   # permission set do operador (cloudlab-operator, via IAM Identity Center), roles do EKS, budget alert
  modules/         # vpc, eks -- módulos reutilizáveis chamados por envs/lab
  envs/lab/        # VPC, EKS, S3 de vídeo, IAM da app, CloudFront, DNS
gitops/      # manifests da app (Kustomize) e da plataforma (Helm via ArgoCD Application multi-source), reconciliados pelo ArgoCD
app/         # API (FastAPI) e transcoder (FFmpeg) + Dockerfiles
load/        # cenários k6
chaos/       # experimentos de caos (kill pod, drain node, derrubar observabilidade)
docs/        # motivação, ADRs, runbooks e retrospectos por fase
Makefile     # make validate-all -- roda as 6 checagens funcionais em ordem, sem parar no primeiro erro
.github/workflows/  # CI: fmt/validate/tflint, trivy/gitleaks, yamllint/shellcheck/ruff/links -- só checagens estáticas, sem credenciais AWS
```

## Como começar

A sequência completa — de uma conta AWS zerada até `app.<domínio>` servindo vídeo, e de volta a zero ao final da sessão — está em [`docs/runbooks/run-the-project.md`](docs/runbooks/run-the-project.md). Depois do `terraform apply`, `make validate-all` roda todas as checagens funcionais de uma vez (`make help` lista as individuais).

## Status

✅ **Roadmap completo — todas as 6 fases encerradas.** Fundação Terraform: backend remoto, VPC, EKS com node group spot e budget alert ([`docs/phases/001-terraform-foundation.md`](docs/phases/001-terraform-foundation.md)). Aplicação: API (FastAPI) + transcoder (FFmpeg) como Job no EKS, gravando HLS no S3 ([`docs/phases/002-application.md`](docs/phases/002-application.md)). GitOps: ArgoCD reconciliando `gitops/app/` e `gitops/platform/` a partir do Git, sem nenhum `kubectl apply` manual ([`docs/phases/003-gitops.md`](docs/phases/003-gitops.md)). Borda/DNS/TLS: CloudFront + Route 53 + cert-manager servindo `app.<domínio>` com HTTPS válido ([`docs/phases/004-edge-dns-tls.md`](docs/phases/004-edge-dns-tls.md)). Observabilidade: dashboard "dia do jogo" com hit ratio de CDN, latência p95/p99, saturação e erros ([`docs/phases/005-observability.md`](docs/phases/005-observability.md)). Dia do jogo: testes de carga k6, HPA por CPU e experimentos de caos, com relatório final de "o que quebrou primeiro" ([`docs/phases/006-game-day.md`](docs/phases/006-game-day.md)). Trabalho futuro é opcional — ver "Próximos passos" no [`CLAUDE.md`](CLAUDE.md).
