# CLAUDE.md — MiniTube

> Contexto do projeto para o Claude Code. Leia este arquivo por completo antes de qualquer tarefa.
> Este é um arquivo vivo: a seção **Estado atual** é um retrato do presente, não um diário de sessões — histórico de decisões, bugs e retrospectos vive em `docs/adr/` e `docs/phases/`.

## O que é este projeto

O **MiniTube** é uma mini plataforma de streaming de vídeo construída de ponta a ponta como projeto pessoal de estudo em **DevOps e SRE**. Ele reproduz, em miniatura, a arquitetura que permite ao YouTube suportar eventos massivos — a inspiração foi o recorde de público simultâneo nas lives dos jogos da Copa do Mundo transmitidos pela CazéTV.

A história completa da motivação está em [`docs/000-motivation.md`](docs/000-motivation.md). Em resumo: entender **por que** a arquitetura de streaming em escala funciona (cache na borda, camadas que filtram tráfego, origem com autoscaling) construindo uma versão reduzida dela e submetendo-a a testes de carga — o "dia do jogo".

## Objetivos de aprendizado

Praticar de forma integrada: **Terraform** (o autor está se preparando para a certificação Terraform Associate), **Kubernetes/EKS**, **GitOps com ArgoCD**, **observabilidade** (Prometheus, Grafana, Loki, SLOs) e **engenharia de confiabilidade** (testes de carga com k6, autoscaling, resposta a incidentes).

## Princípios inegociáveis

1. **Infraestrutura efêmera.** O ciclo é: `apply` → testar/observar → `destroy`. O EKS cobra pelo control plane mesmo ocioso, então **nenhuma sessão termina com infraestrutura de pé**, salvo decisão explícita registrada aqui. Recriar o ambiente do zero deve ser indolor — se doer, o código ainda não está bom.
2. **Tudo é código.** Infraestrutura (Terraform), deploys (manifests GitOps), alertas de orçamento e dashboards. Nada de mudanças manuais no console — se acontecer em emergência, deve ser codificada em seguida.
3. **Documentação contínua.** Todo marco relevante gera ou atualiza documentação em `docs/`. Decisões de arquitetura viram ADRs curtos (`docs/adr/`).
4. **Custo controlado.** Budget alert na conta (criado via Terraform na fase 1), instâncias spot pequenas, um único NAT Gateway. Custo estimado deve ser mencionado no plano de qualquer recurso novo.
5. **Aprendizado antes de velocidade.** O autor quer entender cada bloco de baixo para cima. Explique o *porquê* antes do *como*; prefira escrever módulos próprios a copiar módulos prontos quando o objetivo for didático.

## Arquitetura alvo

```
Espectadores (k6) ──▶ CloudFront (CDN, cache na borda) ──▶ S3 (segmentos HLS — origem)
                            │
                            └──(rotas dinâmicas)──▶ ALB ──▶ EKS (VPC privada)
                                                            ├── app: API + transcoder (FFmpeg → HLS → S3)
                                                            └── plataforma: ArgoCD, kube-prometheus-stack, Loki
```

- **Fluxo de vídeo:** o transcoder lê o vídeo bruto, gera variantes HLS com FFmpeg e grava os segmentos no S3; o CloudFront serve os segmentos com cache na borda. A imensa maioria das requisições deve morrer no CDN — o *hit ratio* é uma métrica central do projeto.
- **Fluxo dinâmico:** API e páginas passam pelo ALB até o EKS.
- **DNS e TLS:** o autor possui um **domínio próprio ativo**. Zona hospedada no Route 53 (ou delegação de subdomínio), com `external-dns` publicando registros e `cert-manager` emitindo certificados Let's Encrypt. URLs alvo: `grafana.<domínio>`, `argocd.<domínio>`, `app.<domínio>`. A zona DNS pode ser o único recurso persistente entre sessões (custo baixo e fixo) — decisão a registrar em ADR na fase 4.

## Estrutura do repositório

```
minitube/
├── CLAUDE.md               # este arquivo — contexto e estado vivo
├── README.md               # visão geral e quick start
├── docs/
│   ├── 000-motivation.md   # por que o projeto existe
│   ├── engineering-standards.md  # padrões reutilizáveis (git, gitops, iac) — importado pelo CLAUDE.md
│   ├── adr/                # decisões de arquitetura (curtas, numeradas)
│   ├── runbooks/           # bootstrap/, validate/, chaos/, load/ (por categoria) + access-argocd-ui.md, incident-response.md na raiz
│   └── phases/             # retrospecto de cada fase concluída, insumo da documentação final do projeto
├── terraform/
│   ├── bootstrap/          # backend remoto: bucket S3 de estado (versionado, com lock); repositórios ECR
│   ├── bootstrap-iam/      # roles IAM, permission set do operador, budget alert (persistente, admin-only)
│   ├── modules/            # vpc, eks — módulos reutilizáveis chamados por envs/lab (ADR 013)
│   └── envs/lab/           # VPC, EKS, S3 de vídeo, IAM da app (IRSA), CloudFront, DNS
├── gitops/
│   ├── platform/           # kube-prometheus-stack, loki (Helm/Kustomize, Fase 5) — ArgoCD em si é instalado via terraform/envs/lab/
│   └── app/                # api e transcoder (Kustomize, reconciliado pelo ArgoCD)
├── app/
│   ├── api/                # FastAPI: upload + dispara Job de transcodificação
│   └── transcoder/         # FFmpeg → HLS, roda como Job Kubernetes
├── load/                   # cenários k6 ("ondas de torcida")
└── chaos/                  # experimentos de caos simples (Fase 6)
```

## Fases do projeto

Cada fase tem um critério de conclusão explícito. Não avançar de fase sem fechá-lo e documentá-lo.

| Fase | Entregável | Critério de conclusão |
| ---- | ---------- | --------------------- |
| **0 — Documentação** | `docs/000-motivation.md`, `README.md`, este `CLAUDE.md` | Repositório criado com a base documental commitada |
| **1 — Fundação Terraform** | Bootstrap do backend remoto; módulo próprio de VPC (subnets públicas/privadas, 1 NAT); EKS com node group spot; budget alert | `terraform destroy` completo seguido de `apply` limpo, sem passos manuais |
| **2 — Aplicação** | API mínima + job de transcodificação (FFmpeg → variantes HLS → S3), com Dockerfiles | Um vídeo de teste transcodificado e segmentos legíveis no S3 |
| **3 — GitOps** | ArgoCD instalado; app e plataforma sincronizados a partir de `gitops/` | Nenhum `kubectl apply` manual — todo deploy sai do Git |
| **4 — Borda, DNS e TLS** | CloudFront na frente do S3; Route 53 + external-dns + cert-manager com o domínio próprio | `app.<domínio>` servindo vídeo via CDN com HTTPS válido; ADR sobre persistência da zona DNS |
| **5 — Observabilidade** | kube-prometheus-stack, Loki, dashboards; SLOs de latência e disponibilidade definidos **antes** dos testes | Dashboard "dia do jogo" mostrando hit ratio do CDN, latência p95/p99, saturação e erros |
| **6 — Dia do jogo** | Cenários k6 em ondas; HPA (e opcionalmente KEDA); experimentos de caos simples; runbook de incidente | Relatório final em `docs/` com gráficos, o que quebrou primeiro e lições aprendidas |

## Convenções de trabalho (para o Claude Code)

- **Padrões de engenharia:** este projeto segue integralmente @docs/engineering-standards.md (branches, commits, GitOps, IaC, segurança) — o Claude Code importa esse arquivo automaticamente.
- **Idioma:** nomes de diretórios e arquivos, commits, branches, código e identificadores sempre em **inglês**; o conteúdo da documentação (`docs/`, README, este arquivo) e a comunicação em **português do Brasil**.
- **Documentação oficial primeiro:** ao implementar com qualquer ferramenta (Terraform, Kubernetes, ArgoCD, CI/CD...), seguir sua documentação oficial e guias de melhores práticas; em caso de dúvida, consultar a documentação atual antes de implementar.
- **Didática:** o autor prefere entender de baixo para cima. Antes de aplicar algo novo, explique brevemente o conceito e o porquê da escolha. Prepare bem antes de implementar.
- **Terraform:** sempre `terraform plan` revisado antes de qualquer `apply`. Nunca `apply -auto-approve` em recursos novos.
- **Comandos destrutivos:** sempre dry-run ou revisão prévia (ex.: `terraform plan -destroy` antes de `destroy`; conferir contexto do kubectl antes de deletar recursos).
- **Commits e branches:** Conventional Commits **em inglês** e trunk-based development com branches curtas, conforme `docs/engineering-standards.md` — ex.: `feat(terraform): add vpc module`, branch `feat/vpc-module`.
- **Segredos:** nunca commitar credenciais, kubeconfig ou `*.tfstate`. Estado fica no backend remoto S3; garantir `.gitignore` adequado desde o primeiro commit.
- **Fim de sessão:** produzir um resumo do que foi feito; atualizar a seção **Estado atual** só quando o retrato mudar (infraestrutura de pé, próximos passos) — decisão de arquitetura vira ADR, retrospecto de fase vira `docs/phases/`, não uma entrada nova aqui. Confirmar que a infraestrutura foi destruída (ou registrar explicitamente o que ficou de pé e por quê).

## Runbook resumido de sessão

**Subir:** `cd terraform/envs/lab` → `terraform plan` (revisar) → `terraform apply` → validar acesso ao cluster → (fase 3+) ArgoCD sincroniza o resto.

**Derrubar:** confirmar que nada precisa persistir → `terraform plan -destroy` (revisar) → `terraform destroy` → conferir no console/CLI que não restaram recursos cobráveis (EKS, NAT, ALB, EC2, EIP) → atualizar Estado atual.

## Estado atual

> Retrato do presente — não um diário. Histórico de decisões, bugs reais e retrospectos de cada fase vive em `docs/adr/` (001–013) e `docs/phases/` (001–006).

- **Roadmap completo.** Todas as 6 fases encerradas e validadas funcionalmente (critérios de conclusão cumpridos, ver tabela acima). Trabalho futuro é opcional, listado abaixo.
- **Infraestrutura persistente entre sessões** (sem custo relevante — ver ADR 001, 004, 005): bucket de state S3; IAM Identity Center (permission set `cloudlab-operator`, roles do EKS, role de smoke test, budget alert) em `terraform/bootstrap-iam/`; dois repositórios ECR, hosted zone Route 53, certificado ACM wildcard e o parâmetro SSM da deploy key do ArgoCD em `terraform/bootstrap/`.
- **`terraform/envs/lab/`** (VPC, EKS, S3 de vídeo, ArgoCD, CloudFront, observabilidade) é efêmero por design: sobe no início da sessão, é destruído por completo ao final, sempre confirmado sem recursos órfãos via API AWS direta. Estado no momento: **destruído**.
- **Organização de repositório concluída** (pós-roadmap, preparação para tornar o repositório público): nomes de arquivo/diretório em inglês (PR #36); módulos Terraform próprios `vpc`/`eks` (PR #37, [ADR 013](docs/adr/013-terraform-vpc-eks-modules.md)); `docs/runbooks/` organizado por categoria (PR #38); `load/README.md` documentando a cobertura dos scripts de carga (PR #39).
- **Próximos passos (opcionais, sem fase formal associada):**
  1. Achar o teto exato de capacidade além do já confirmado `PEAK_RATE=800`/`maxReplicas: 6` (escalar mais, ou subir `maxReplicas`).
  2. KEDA como alternativa ao HPA por CPU.
  3. Habilitar "Additional metrics" no CloudFront, se o hit ratio real no dashboard for importante.
  4. CI (GitHub Actions: `terraform fmt`/`validate`, lint de manifests) — ainda não implementado.
  5. Tornar o repositório público para portfólio/LinkedIn (decisão de fundo já registrada no [ADR 007](docs/adr/007-argocd-gitops-bootstrap.md)) — pendente de concluir a rodada de organização em andamento.
