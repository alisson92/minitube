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
│   ├── bootstrap-iam/      # roles IAM, permission set do operador, budget alert (persistente, admin-only)
│   └── envs/lab/           # VPC, EKS, S3 de vídeo, CloudFront, DNS
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

- **Fase atual:** 2 — Aplicação (Fase 1 encerrada por completo)
- **Infraestrutura de pé:** bucket de state `minitube-tfstate-479213212405` (versionado, criptografado AES256, sem acesso público, `prevent_destroy` ativo); IAM Identity Center habilitado na conta, com o usuário `alisson.cloudlab@gmail.com` e o Permission Set `cloudlab-operator` (policy `PowerUserAccess`) atribuído via `aws_ssoadmin_account_assignment`. Tudo criado e verificado na conta AWS `479213212405`.
- **Conta AWS:** a conta antiga (`455162168775`, usuário `lab-operator`) foi abandonada por não ser rastreável (origem/administrador desconhecidos). Nova conta dedicada com e-mail `alisson.cloudlab@gmail.com`, para uso em múltiplos projetos pessoais de laboratório, não só o MiniTube. Decisão registrada em [`docs/adr/002-aws-account-and-iam-bootstrap.md`](docs/adr/002-aws-account-and-iam-bootstrap.md).
- **Módulos de bootstrap separados:** `terraform/bootstrap/` (bucket S3, uso diário liso com `cloudlab-operator` via SSO, local) e `terraform/bootstrap-iam/` (Permission Set + account assignment do IAM Identity Center — só roda com sessão root/CloudShell, pois `PowerUserAccess` e os recursos `aws_ssoadmin_*`/`aws_identitystore_*` continuam fora do alcance do operador diário). Ver ADR 002 e ADR 003.
- **Exceção registrada ao princípio de efemeridade:** o bucket S3 de state é infraestrutura intencionalmente persistente entre sessões. Ver ADR 001.
- **Migração para IAM Identity Center (SSO) concluída e verificada** (ADR 003, PR #3): `cloudlab-operator` deixou de ser um `aws_iam_user` com access key estática e passou a ser um Permission Set do IAM Identity Center. Validado ponta a ponta: `aws sso login --profile cloudlab` + `get-caller-identity` retornando o assumed-role correto; `terraform plan` limpo ("No changes") em `bootstrap/` via `AWS_PROFILE=cloudlab`; usuário IAM estático antigo confirmado como destruído (console + `aws iam list-access-keys` via CloudShell retornando `NoSuchEntity`). Nenhuma credencial estática de operador humano resta na conta.
- **Lição aprendida (registrada no runbook):** o CloudShell tem só 1 GB de storage persistente em `$HOME` — rodar `terraform init` em múltiplos diretórios na mesma sessão sem `TF_PLUGIN_CACHE_DIR` compartilhado esgota o disco (`no space left on device`). Também: credenciais estáticas em `~/.aws/credentials` têm precedência sobre `sso_session` do mesmo profile em `~/.aws/config` — é preciso remover a entrada antiga *antes* de testar o profile SSO, senão o erro é um `InvalidClientTokenId` confuso.
- **Lição aprendida — PowerUserAccess bloqueia IAM por completo:** não é só escrita — `iam:GetRole`, `iam:GetInstanceProfile` e `iam:PassRole` também retornam `AccessDenied` para o `cloudlab-operator`. Qualquer módulo que precise passar uma role para um recurso (ex.: instance profile de EC2) precisa de uma policy inline **estreita** no permission set (só as ações e o ARN necessários), aplicada via `bootstrap-iam`/CloudShell — não existe leitura "de graça" em IAM sob essa policy.
- **Lição aprendida — não rodar `terraform apply`/`destroy` fora do fluxo com o backend S3 confirmado:** nesta sessão um `destroy` manual de teste em `terraform/envs/lab/` (para validar algo) ficou sem o `apply` de volta por um instante, e a checagem cruzada (`terraform state list` vs `aws ec2 describe-vpcs`) foi o que revelou a divergência antes de qualquer ação destrutiva real. Sempre conferir `terraform plan` mostrando `No changes` antes de confiar no state depois de qualquer operação manual fora do fluxo assistido.
- **Módulo de VPC (`terraform/envs/lab/`) aplicado e validado funcionalmente:** VPC `10.0.0.0/16`, 2 AZs (`us-east-1a`/`us-east-1b`), 2 subnets públicas (`/24`) + 2 privadas (`/20`), 1 Internet Gateway, 1 NAT Gateway único (subnet pública `us-east-1a`) com as route tables corretas. Validação não parou em `describe-*`: o script `terraform/envs/lab/scripts/validate-network.sh` sobe uma instância EC2 efêmera na subnet privada (acesso só via SSM Session Manager, sem SSH/bastion) e confirma egress real de internet através do NAT — todas as checagens passaram (IP no CIDR certo, SSM online, `curl` externo, DNS público), instância sempre terminada ao final via `trap`. Runbook em [`docs/runbooks/validate-vpc-network.md`](docs/runbooks/validate-vpc-network.md); padrão de "validação funcional pós-apply" registrado como prática permanente em [`docs/engineering-standards.md`](docs/engineering-standards.md) (seção 11), para ser reaplicado nas próximas fases (EKS, CloudFront, etc.).
- **Role de smoke test em `terraform/bootstrap-iam/`:** `minitube-network-smoke-test` (role + instance profile + policy `AmazonSSMManagedInstanceCore`), com uma policy inline no permission set do operador liberando `iam:PassRole`/`iam:GetInstanceProfile` só nesse ARN. Aplicada via CloudShell/root; reutilizável por futuros scripts de validação, sem custo, não precisa ser destruída entre sessões.
- **Feito até aqui:** Fase 0 commitada e enviada; conta AWS nova criada e bootstrapada; ADR 001 e ADR 002 registrados; migração completa para IAM Identity Center (ADR 003); módulo de VPC criado, aplicado e validado funcionalmente com smoke test via SSM — tudo nesta sessão.
- **Infraestrutura de pé:** só o bucket de state e o IAM Identity Center (`cloudlab-operator` + a role `minitube-network-smoke-test` +, a partir desta sessão, `minitube-eks-cluster-role`/`minitube-eks-node-role`), todos persistentes por design (`terraform/bootstrap-iam/`, sem custo). `terraform/envs/lab/` (VPC + EKS) foi **destruído ao final da sessão** (`terraform destroy`, `plan -destroy` revisado antes) — princípio de infraestrutura efêmera respeitado.
- **PR #5** (`feat/vpc-module`: módulo de VPC + smoke test via SSM + padrão de validação funcional) mergeado em `main`; branch remota e local removidas.
- **Módulo de EKS criado, aplicado e validado funcionalmente** (branch `feat/eks-node-group`, ADR 004): `terraform/bootstrap-iam/main.tf` ganhou as roles `minitube-eks-cluster-role` e `minitube-eks-node-role` (+ service-linked roles condicionais) e a policy inline única do permission set (`operator_pass_smoke_test_role` renomeada para `operator_pass_roles`, unificando os `Statement` — a API do Identity Center só aceita uma inline policy por permission set). `terraform/envs/lab/eks.tf` define `aws_eks_cluster` (`authentication_mode = "API"`), `aws_eks_node_group` gerenciado spot (`2x t3.medium`, min=1/max=3/desired=2) e `aws_iam_openid_connect_provider` (IRSA, criado antecipadamente). Tags `kubernetes.io/cluster/minitube-lab=shared` adicionadas às subnets existentes.
  Executado via CloudShell nesta sessão: `apply` limpo em `bootstrap-iam`; `apply` em `envs/lab` criou os 19 recursos esperados (16 da VPC recriada do zero + 3 do EKS: cluster, node group, OIDC provider); `scripts/validate-eks.sh` **e** `scripts/validate-network.sh` passaram sem erros (control plane acessível, nodes spot `Ready`, pod real agendado e executado, egress via NAT confirmado); `terraform destroy` removeu os 19 recursos por completo. Critério de conclusão do entregável EKS da Fase 1 fechado — `bootstrap-iam` não foi tocado no destroy (roles persistem, sem custo).
- **Regra de custo para esta e futuras fases (CloudFront, etc.):** só o que está em `terraform/bootstrap-iam/` (roles, permission set, budget alert) e o bucket de state + IAM Identity Center ficam de pé entre sessões, porque não geram custo. Todo o resto — VPC, EKS, CloudFront, e o que vier nas fases seguintes — é criado do zero em `terraform/envs/lab/` no início de cada sessão de teste e destruído por completo ao final dela, sempre com `terraform plan -destroy` revisado antes. Confirmado na sessão anterior: ciclo completo apply→validate→destroy do EKS não deixou nada de pé além de `bootstrap-iam`.
- **Budget alert criado, aplicado e validado funcionalmente** (branch `feat/budget-alert`, ADR 005): `terraform/bootstrap-iam/budget.tf` define `aws_budgets_budget.account_cost` — `minitube-monthly-cost-alert`, cobrindo o custo total da conta (sem `cost_filter`), limite de **10 USD/MONTHLY**, com duas notificações por e-mail direto (sem SNS) para `alisson.cloudlab@gmail.com`: `FORECASTED` em 80% e `ACTUAL` em 100%. Persistente por design em `bootstrap-iam/`, fora do ciclo efêmero de `envs/lab/` — o mesmo motivo estrutural do ADR 004, com justificativa própria (cobertura de gasto esquecido entre sessões).
  Executado via CloudShell nesta sessão: `apply` limpo (1 recurso novo, nada mais mudou); `scripts/validate-budget.sh` passou nas 5 checagens (budget existe, limite correto, ambas notificações configuradas, e-mail assinante confirmado via `describe-subscribers-for-notification`). Um bug de sintaxe no script (parâmetros do `aws budgets describe-subscribers-for-notification` em `kebab-case` em vez de `PascalCase`) foi corrigido e revalidado com sucesso. Runbook em [`docs/runbooks/validate-budget-alert.md`](docs/runbooks/validate-budget-alert.md) — documenta a limitação conhecida de que a AWS Budgets recalcula gasto no próprio schedule, então o script valida configuração, não o disparo real do alerta.
- **Fase 1 (Fundação Terraform) formalmente encerrada.** Todos os entregáveis da tabela de fases cumpridos e validados: backend remoto, módulo de VPC, EKS com node group spot, budget alert. `terraform/envs/lab/` segue destruído (nenhuma infra nova ficou de pé nesta sessão além do que já persistia em `bootstrap-iam/`).
- **Próximos passos:** (1) abrir PR de `feat/budget-alert` para `main`; (2) após o merge, iniciar a Fase 2 (API mínima + job de transcodificação FFmpeg → HLS → S3, com Dockerfiles).
