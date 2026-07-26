# Fase 5 — Observabilidade

> Retrospecto da fase, escrito ao final dela. Não repete o conteúdo de ADRs e runbooks — linka para eles. Serve como insumo para a documentação final do projeto (ver `CLAUDE.md`, seção "Estrutura do repositório").
>
> **Nota sobre este arquivo:** escrito em backfill (Fase 6), a partir da seção "Estado atual" do `CLAUDE.md` e do ADR 011 — a série de retrospectos parou em `003-gitops.md` e só foi retomada ao planejar o fechamento da Fase 6.

## Objetivo da fase

Instalar `kube-prometheus-stack` e Loki via GitOps, com SLOs de latência e disponibilidade definidos **antes** dos testes de carga da Fase 6. Critério de conclusão (`CLAUDE.md`): *"Dashboard 'dia do jogo' mostrando hit ratio do CDN, latência p95/p99, saturação e erros"*.

## O que foi entregue

| Entregável | Onde vive | Persistente ou efêmero |
| --- | --- | --- |
| Node sizing `3/3/3` (sem Cluster Autoscaler) | `terraform/envs/lab/variables.tf` | Efêmero |
| EBS CSI driver (provisionador de volume dinâmico, antes inexistente) | `gitops/platform/ebs-csi-driver/` | Efêmero |
| kube-prometheus-stack (Prometheus, Alertmanager, Grafana) | `gitops/platform/kube-prometheus-stack/` | Efêmero |
| Loki + Promtail (single-binary, storage filesystem via PVC) | `gitops/platform/{loki,promtail}/` | Efêmero |
| 2 novas IRSA roles (`ebs-csi-driver`, `grafana` — esta com leitura de CloudWatch) | `terraform/envs/lab/iam-platform.tf` | Efêmero |
| Instrumentação `/metrics` na API (`prometheus-fastapi-instrumentator`) | `app/api/main.py`, imagem `v0.1.3` | — |
| `PrometheusRule` com os 2 SLOs mínimos viáveis (disponibilidade + latência) | `gitops/platform/kube-prometheus-stack/slo-rules.yaml` | Efêmero |
| Grafana exposto via Ingress (`grafana.<domínio>`) | `gitops/platform/kube-prometheus-stack/values.yaml` + Ingress | Efêmero |
| Novo `Sid AttachEbsCsiManagedPolicy` no permission set do operador | `terraform/bootstrap-iam/main.tf` | Persistente |

## Decisões de arquitetura (ADRs)

- **[ADR 011](../adr/011-observability-stack.md)** — decisão central da fase. Quatro decisões de escopo fechadas com o operador: node sizing `min=max=desired=3` (gargalo real é o limite de 17 pods/nó via VPC CNI, não CPU/memória; autoscaler real adiado deliberadamente para a Fase 6, guiado por carga do k6); Loki single-binary + filesystem (não distributed + S3, sem ganho num ambiente efêmero); EBS CSI driver via GitOps (não `aws_eks_addon`, mantém um único mecanismo de add-on); Grafana com IRSA própria e leitura de CloudWatch (hit ratio do CDN e erros da ALB só existem lá, não no Prometheus — sem essa role o critério de conclusão da fase não é cumprível). SLO definido como "mínimo viável, não elaborado": disponibilidade de graça via kube-state-metrics, latência com limiar de 500ms **arbitrário**, explicitamente marcado para revisão com dado real na Fase 6.

## Bugs reais encontrados e corrigidos

Nenhum destes apareceu em `helm template`/`terraform validate` — só ao sincronizar de verdade contra o cluster:

1. **Chart do Loki falha o render** se `SingleBinary` e os componentes do modo `SimpleScalable` (`write`/`read`/`backend`) tiverem réplicas > 0 simultaneamente — corrigido zerando os três explicitamente.
2. **Loki 3.x exige `compactor.delete_request_store`** quando a retenção está habilitada, senão `loki-0` entra em `CrashLoopBackOff` — efeito cascata: os 3 `promtail` ficavam com readiness falhando por não conseguirem falar com um Loki fora do ar.
3. **Webhook de admissão do Prometheus Operator via Jobs de Helm trava o sync no ArgoCD** — os Jobs de hook (`admission-create`/`admission-patch`) competem com o ciclo de sync/prune do ArgoCD. Corrigido trocando para o cert-manager (já rodando desde a Fase 4) gerar o certificado internamente, eliminando os Jobs.
4. **CRDs do Prometheus Operator grandes demais para *client-side apply*** — `metadata.annotations: Too long: must have at most 262144 bytes`. Corrigido com `ServerSideApply=true` no `syncOptions` dessa Application.
5. **O operator descobre CRDs só na inicialização** — como subiu antes das CRDs existirem de verdade (efeito colateral do troubleshooting ao vivo, com múltiplos syncs parciais), continuou rodando com cache desatualizado mesmo depois das CRDs aplicarem. Exigiu `kubectl rollout restart` manual; não necessariamente um bug estrutural (candidato a monitorar num `apply` limpo do zero).
6. **Senha de admin do Grafana regenerada a cada sync do ArgoCD** — o chart gera a senha via `randAlphaNum` no próprio template, seguro sob `helm install`/`upgrade` real, mas não sob o ArgoCD (renderiza sem estado a cada sync). Corrigido gerando a senha uma única vez em estado real do Terraform (`random_password.grafana_admin`), injetada via `helm.parameters`.

## Como validamos

[`docs/runbooks/validate/validate-observability.md`](../runbooks/validate/validate-observability.md) + `scripts/validate-observability.sh`: PVCs `Bound` via o EBS CSI driver, Prometheus sem targets down e scrapeando a própria API, Grafana acessível com login funcional, Loki com logs reais do `promtail`. Dashboard conferido visualmente pelo operador — os 4 sinais do critério de conclusão da fase (hit ratio do CDN, latência p95/p99, saturação, erros). Ciclo completo `apply`→`validate`→`destroy` confirmado limpo via `aws ec2 describe-volumes` — o risco teórico de volume EBS órfão (mesma classe de bug do ADR 010) **não se confirmou**.

## Lições aprendidas

- **Um `values.yaml` de chart complexo pode gerar efeitos colaterais não óbvios no ciclo de vida do ArgoCD** (Jobs de hook, annotations grandes) que só aparecem em sync real, nunca em `helm template` isolado — reforça, mais uma vez, "existe vs. funciona" (`docs/engineering-standards.md` §11).
- **Operators Kubernetes que fazem descoberta de API só na inicialização são sensíveis à ordem de aplicação de CRDs** — um sync parcial/iterativo (comum durante troubleshooting ao vivo) pode deixar um cache desatualizado que só um restart resolve, mesmo com o resto do sistema já correto.
- **Segredos gerados por template Helm sem estado real (`randAlphaNum` e afins) são incompatíveis com reconciliação sem estado (ArgoCD)** — sempre que o valor precisa ser estável entre syncs, gerar fora do chart (Terraform, secret manager) e injetar via parâmetro.

## Estado final da fase

- Critério de conclusão cumprido: dashboard "dia do jogo" no Grafana, confirmado visualmente pelo operador, com os 4 sinais exigidos.
- `terraform/bootstrap-iam/` ganhou o `Sid AttachEbsCsiManagedPolicy` (persistente); `terraform/envs/lab/` confirmado destruído ao final da sessão, sem volumes EBS órfãos.
- PR desta fase: #18 (`feat/phase-5-observability`).

## Próxima fase

[Fase 6 — Dia do jogo](../../CLAUDE.md#fases-do-projeto): cenários k6 em ondas, HPA (e opcionalmente KEDA), experimentos de caos simples, runbook de incidente — critério de conclusão: relatório final em `docs/` com gráficos, o que quebrou primeiro e lições aprendidas.
