# Fase 1 — Fundação Terraform

> Retrospecto da fase, escrito ao final dela. Não repete o conteúdo de ADRs e runbooks — linka para eles. Serve como insumo para a documentação final do projeto (ver `CLAUDE.md`, seção "Estrutura do repositório").

## Objetivo da fase

Construir a base de infraestrutura como código sobre a qual todas as fases seguintes se apoiam: backend remoto de state, uma conta AWS com identidade e privilégios bem definidos, uma VPC própria e um cluster EKS com node group spot — tudo aplicável do zero e destrutível por completo, sem passos manuais escondidos. O critério de conclusão original (`CLAUDE.md`): *"`terraform destroy` completo seguido de `apply` limpo, sem passos manuais"*.

## O que foi entregue

| Entregável | Onde vive | Persistente ou efêmero |
| --- | --- | --- |
| Backend remoto de state (bucket S3 + lock nativo) | `terraform/bootstrap/` | Persistente |
| Conta AWS dedicada + operador via IAM Identity Center (SSO) | `terraform/bootstrap-iam/` | Persistente |
| Roles IAM do EKS (cluster/node) + OIDC provider (IRSA) | `terraform/bootstrap-iam/` + `terraform/envs/lab/eks.tf` | Roles persistentes; cluster efêmero |
| VPC (2 AZs, subnets públicas/privadas, 1 NAT Gateway) | `terraform/envs/lab/vpc.tf` | Efêmero |
| EKS + node group gerenciado spot (2× t3.medium) | `terraform/envs/lab/eks.tf` | Efêmero |
| Budget alert (10 USD/mês, e-mail em 80%/100%) | `terraform/bootstrap-iam/budget.tf` | Persistente |

A divisão persistente/efêmero não foi um detalhe de organização — foi a decisão de arquitetura mais recorrente da fase (ver seção seguinte).

## Decisões de arquitetura (ADRs)

Cada uma resolveu um problema concreto encontrado durante a fase, não uma escolha abstrata de "melhores práticas":

- **[ADR 001](../adr/001-terraform-state-backend.md) — Backend remoto com lock nativo do S3.** Evita a dependência de uma tabela DynamoDB adicional, usando o lock nativo (`use_lockfile`) disponível desde o Terraform 1.10.
- **[ADR 002](../adr/002-aws-account-and-iam-bootstrap.md) — Conta AWS dedicada e separação `bootstrap`/`bootstrap-iam`.** Nasceu de um erro real: o primeiro `apply` falhou porque a conta herdada de um projeto anterior não tinha o `lab-operator` rastreável nem `s3:CreateBucket`. A separação em dois módulos (um de uso diário, outro admin-only) resolveu um segundo problema — `PowerUserAccess` bloqueia toda leitura de IAM, então o state de recursos IAM não pode nem ser planejado pelo operador diário.
- **[ADR 003](../adr/003-cloudlab-operator-sso-migration.md) — Migração para IAM Identity Center.** Substituiu a `aws_iam_access_key` estática do operador por credenciais temporárias via `aws sso login`, eliminando a última credencial de longa duração da conta.
- **[ADR 004](../adr/004-eks-iam-roles-and-access-mode.md) — Roles do EKS persistentes, `authentication_mode = "API"`, node group gerenciado, OIDC provider antecipado.** Consolidou o padrão "roles IAM vivem em `bootstrap-iam`" já estabelecido pelo ADR 002, e adotou o modo de autenticação por access entries em vez do `aws-auth` ConfigMap legado.
- **[ADR 005](../adr/005-budget-alert-persistence.md) — Budget alert persistente, sem SNS.** Aplicou o mesmo raciocínio de persistência do ADR 004 a um problema diferente: um alerta de custo só é útil se sobreviver ao próprio ciclo de destroy que ele existe para vigiar.

**O fio condutor dos cinco ADRs:** infraestrutura efêmera por padrão, com exceções expressas e documentadas — nunca implícitas. Toda vez que algo precisou persistir (state, identidade, roles, alerta de custo), isso foi uma decisão registrada, não um esquecimento.

## Como validamos

Seguindo o padrão de "validação funcional pós-apply" (`docs/engineering-standards.md`, seção 11) — `describe-*` prova que o recurso existe, não que funciona:

- **Rede:** [`docs/runbooks/validate/validate-vpc-network.md`](../runbooks/validate/validate-vpc-network.md) — instância EC2 efêmera na subnet privada confirma egress real via NAT (SSM-only, sem bastion).
- **EKS:** [`docs/runbooks/validate/validate-eks-cluster.md`](../runbooks/validate/validate-eks-cluster.md) — kubeconfig efêmero, pod real agendado e executado num node spot, logs conferidos.
- **Budget alert:** [`docs/runbooks/validate/validate-budget-alert.md`](../runbooks/validate/validate-budget-alert.md) — configuração confirmada via API; documenta a limitação de que a AWS Budgets recalcula gasto no próprio schedule, então o disparo real do alerta não pode ser forçado sob demanda.

## Lições aprendidas

- **`PowerUserAccess` bloqueia leitura de IAM, não só escrita.** `iam:GetRole`, `iam:GetInstanceProfile` e `iam:PassRole` retornam `AccessDenied` para o operador diário — qualquer recurso que precise passar uma role (instance profile, cluster EKS) exige uma policy inline estreita, escopada por ARN, aplicada via sessão admin.
- **CloudShell tem só 1 GB de `$HOME` persistente.** Rodar `terraform init` em vários módulos na mesma sessão sem plugin cache compartilhado esgota o disco.
- **Credenciais estáticas em `~/.aws/credentials` vencem `sso_session` do mesmo profile em `~/.aws/config`.** Um profile SSO mal configurado com uma entrada estática antiga produz um `InvalidClientTokenId` confuso, não um erro óbvio de autenticação.
- **Operações manuais fora do fluxo assistido merecem checagem cruzada.** Um `destroy` manual de teste em `envs/lab` só foi confirmado como seguro comparando `terraform state list` com `aws ec2 describe-vpcs` antes de qualquer ação destrutiva.
- **A AWS Budgets não recalcula em tempo real.** Validação funcional de custo tem um teto: dá para provar que a configuração está correta, não que o alerta dispara — a prova final só vem organicamente, com o uso real da conta.

## Estado final da fase

- Critério de conclusão cumprido: `terraform destroy` completo em `envs/lab` seguido de `apply` limpo, sem passos manuais, repetido com sucesso para VPC, EKS e (agora, indiretamente) o budget alert em `bootstrap-iam`.
- Infraestrutura de pé entre sessões, por design: bucket de state, IAM Identity Center (permission set + roles do EKS + role de smoke test) e o budget alert — todos sem custo recorrente relevante.
- `terraform/envs/lab/` (VPC + EKS) destruído ao final de cada sessão de teste.
- PRs: [#5](https://github.com/alisson92/minitube/pull/5) (VPC), [#7](https://github.com/alisson92/minitube/pull/7) (EKS), [#8](https://github.com/alisson92/minitube/pull/8) (budget alert).

## Próxima fase

[Fase 2 — Aplicação](../../CLAUDE.md#fases-do-projeto): API mínima + job de transcodificação (FFmpeg → HLS → S3), critério de conclusão: um vídeo de teste transcodificado com segmentos legíveis no S3.
