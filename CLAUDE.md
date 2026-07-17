# CLAUDE.md — MiniTube

> Contexto do projeto para o Claude Code. Leia este arquivo por completo antes de qualquer tarefa.
> Este é um arquivo vivo: a seção **Estado atual** deve ser atualizada ao final de cada sessão.

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
│   └── runbooks/           # subir ambiente, derrubar ambiente, dia do jogo
├── terraform/
│   ├── bootstrap/          # backend remoto: bucket S3 de estado (versionado, com lock)
│   └── envs/lab/           # VPC, EKS, S3 de vídeo, CloudFront, DNS, budget alert
├── gitops/
│   ├── plataforma/         # argocd, kube-prometheus-stack, loki (Helm/Kustomize)
│   └── app/                # api e transcoder (Kustomize)
├── app/                    # código-fonte + Dockerfiles
└── load/                   # cenários k6 ("ondas de torcida")
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
- **Fim de sessão:** produzir um resumo do que foi feito e **atualizar a seção Estado atual deste arquivo** no mesmo commit. Confirmar que a infraestrutura foi destruída (ou registrar explicitamente o que ficou de pé e por quê).

## Runbook resumido de sessão

**Subir:** `cd terraform/envs/lab` → `terraform plan` (revisar) → `terraform apply` → validar acesso ao cluster → (fase 3+) ArgoCD sincroniza o resto.

**Derrubar:** confirmar que nada precisa persistir → `terraform plan -destroy` (revisar) → `terraform destroy` → conferir no console/CLI que não restaram recursos cobráveis (EKS, NAT, ALB, EC2, EIP) → atualizar Estado atual.

## Estado atual

> Atualizar ao final de cada sessão (data + o que mudou + próximos passos).

- **Fase atual:** 1 — Fundação Terraform (em andamento)
- **Infraestrutura de pé:** nenhuma (primeiro `terraform apply` falhou por falta de permissão do usuário IAM antigo — ver abaixo)
- **Conta AWS:** a conta antiga (`455162168775`, usuário `lab-operator`) foi abandonada por não ser rastreável (origem/administrador desconhecidos). Nova conta dedicada criada com e-mail `alisson.cloudlab@gmail.com`, para uso em múltiplos projetos pessoais de laboratório, não só o MiniTube. Usuário operacional de uso diário: `cloudlab-operator`, criado via Terraform (não manualmente) com policy `PowerUserAccess`. Decisão registrada em [`docs/adr/002-aws-account-and-iam-bootstrap.md`](docs/adr/002-aws-account-and-iam-bootstrap.md).
- **Exceção registrada ao princípio de efemeridade:** o bucket S3 de state (`terraform/bootstrap/`) é infraestrutura intencionalmente persistente entre sessões — sem ele não há onde os ambientes futuros guardarem o `.tfstate`. Ver [`docs/adr/001-terraform-state-backend.md`](docs/adr/001-terraform-state-backend.md). Tem `prevent_destroy` ativo e não deve ser destruído no ciclo normal de `destroy` de cada sessão.
- **Feito até aqui:** Fase 0 commitada e enviada; bootstrap do backend remoto e do usuário operacional escrito em `terraform/bootstrap/` (bucket S3 versionado/criptografado/sem acesso público com lock nativo do S3, mais `cloudlab-operator` + `PowerUserAccess`), `terraform fmt`/`validate`/`plan` executados com sucesso (9 recursos a criar); ADR 001, ADR 002 e runbooks `bootstrap-remote-backend.md` e `aws-account-bootstrap.md` criados
- **Próximos passos:** rodar o `terraform apply` do bootstrap a partir do AWS CloudShell da conta nova (`docs/runbooks/aws-account-bootstrap.md`); configurar profile local `cloudlab`; migrar o state do bootstrap para o bucket (`-migrate-state`); iniciar o módulo próprio de VPC (subnets públicas/privadas, 1 NAT)
