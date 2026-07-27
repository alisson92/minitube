# Inventário de URLs demonstráveis

> Checklist de apoio para capturar prints/evidências do MiniTube rodando de verdade, como preparação para a divulgação em portfólio/LinkedIn combinada no [ADR 007](adr/007-argocd-gitops-bootstrap.md) (decisão de tornar o repositório público **deliberadamente ao final do projeto**, não incidentalmente). Não é um runbook operacional — para subir/derrubar o ambiente ou operá-lo no dia a dia, ver [`docs/runbooks/run-the-project.md`](runbooks/run-the-project.md).

## Página de arquitetura (sempre disponível, mesmo com `envs/lab` destruído)

`https://system-design.minitube.projetodevops.com.br` — versão interativa dos diagramas de `docs/architecture.md`. Diferente das três URLs abaixo, **não depende de `envs/lab` estar de pé**: é servida por `terraform/bootstrap/architecture-site.tf` (S3 + CloudFront, persistente por design, mesma categoria do bucket de state/ECR/hosted zone — ver [ADR 017](adr/017-persistent-architecture-showcase-site.md)). Ideal como o link principal do post, funciona mesmo entre sessões.

## URLs públicas (exigem `envs/lab` aplicado)

| UI | URL | O que mostra | Usuário | Senha |
| --- | --- | --- | --- | --- |
| App (produto) | `https://app.minitube.projetodevops.com.br` (`terraform output -raw app_url`) | O produto em si: upload, transcodificação e reprodução de vídeo via HLS, servido pelo CloudFront | — | — |
| ArgoCD | `https://argocd.minitube.projetodevops.com.br` | GitOps de ponta a ponta: todas as `Application`s `Synced`/`Healthy`, reconciliadas a partir do Git | `admin` | `cd terraform/envs/lab && terraform output -raw argocd_admin_password` — ver [`access-argocd-ui.md`](runbooks/access-argocd-ui.md) |
| Grafana | `https://grafana.minitube.projetodevops.com.br` | Dashboard "dia do jogo" (latência, saturação/HPA, erros), Explore para Loki | `admin` | `cd terraform/envs/lab && terraform output -raw grafana_admin_password` |

Todas as três URLs vêm do mesmo domínio próprio (`var.domain_name`, hosted zone Route 53 em `terraform/bootstrap/dns.tf`), com certificado ACM wildcard — HTTPS válido nas três. Só ficam no ar enquanto `envs/lab` estiver aplicado (ao contrário da página de arquitetura acima).

## O que não tem URL própria

Sem Ingress dedicado — acessíveis só por dentro do Grafana ou via `port-forward` manual (kubeconfig via `aws eks update-kubeconfig`, mesmo padrão usado em `docs/runbooks/incident-response.md`):

- **Prometheus** — datasource default do Grafana (Explore/dashboards já cobrem a maioria dos casos). Para acesso direto:
  ```bash
  kubectl -n minitube-platform port-forward svc/kube-prometheus-stack-prometheus 9090:9090
  ```
- **Alertmanager** — nome de serviço padrão do chart (`kube-prometheus-stack-alertmanager`, porta `9093`), não exercitado neste projeto até agora:
  ```bash
  kubectl -n minitube-platform port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
  ```
- **Loki** — `gateway.enabled: false` (`gitops/platform/loki/values.yaml`); nunca teve exposição própria, só datasource do Grafana (aba Explore) ou:
  ```bash
  kubectl -n minitube-platform port-forward svc/loki 3100:3100
  ```

## Checklist de evidências a capturar

**Lado cliente** (`app.<domínio>`):
- [ ] Player reproduzindo um vídeo real, upload feito de ponta a ponta (`POST /api/videos` → transcodificação → HLS)
- [ ] Aba Network do navegador mostrando os segmentos `.ts`/`.m3u8` vindo do CloudFront, com header `X-Cache` confirmando cache hit (mesma checagem de `scripts/validate-cloudfront-dns-tls.sh`)

**Lado servidor** (o "por baixo dos panos" de engenharia):
- [ ] Dashboard "dia do jogo" no Grafana durante uma carga real de k6 (`load/run-waves-from-ec2.sh` é o cenário mais visual — sobe e desce em ondas)
- [ ] HPA escalando ao vivo: `kubectl -n minitube-app get hpa api -w` (esperado: 2 → 3 → 5 → 6 réplicas subindo, depois voltando a 2 — ver [`run-k6-waves.md`](runbooks/load/run-k6-waves.md))
- [ ] ArgoCD com todas as `Application`s `Synced`/`Healthy`
- [ ] Hit ratio do CDN: o painel do dashboard mostra `No data` por padrão (requer "Additional metrics" do CloudFront, custo extra não habilitado — ver `docs/phases/006-game-day.md`); se quiser esse número no print, é o item 3 dos "Próximos passos" do `CLAUDE.md` — senão, usar o header `X-Cache` como evidência equivalente

## Nota sobre as senhas

Ambas (ArgoCD, Grafana) são geradas pelo Terraform e ficam estáveis **dentro da sessão atual** — regeneram só quando `envs/lab` é destruído e recriado. Se o ambiente for recriado antes do post ser publicado, reexecutar os comandos `terraform output` acima.
