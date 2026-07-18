# 003 — Migração do `cloudlab-operator` para IAM Identity Center (SSO)

## Status

Aceito

## Contexto

O ADR 002 criou o `cloudlab-operator` como `aws_iam_user` com uma `aws_iam_access_key` — uma credencial estática de longa duração, configurada manualmente via `aws configure --profile cloudlab`. Essa lacuna já havia sido registrada como pendência no `CLAUDE.md`: a própria AWS recomenda IAM Identity Center para operadores humanos, já que `aws sso login` gera credenciais temporárias que expiram sozinhas, eliminando a necessidade de rotação manual de access key.

A decisão foi antecipar essa migração para o início da Fase 1, enquanto só dois recursos dependiam da credencial estática (o bucket de state e o próprio usuário IAM) — antes de qualquer outro módulo (VPC, EKS) passar a depender do profile local.

## Decisão

1. **Remover por completo** o `aws_iam_user.operator`, sua policy attachment e sua `aws_iam_access_key` em `terraform/bootstrap-iam/`. Nenhuma credencial estática de operador permanece na conta.
2. **Habilitar IAM Identity Center** na conta (passo manual único, feito via console com sessão root — a AWS não expõe a ativação do serviço via Terraform).
3. **Criar o usuário operador no Identity Center manualmente** (`alisson.cloudlab@gmail.com`), também via console — criar via `aws_identitystore_user` não dispara o fluxo de convite/ativação de senha, então o usuário é criado uma única vez pelo console e apenas **referenciado** via `data "aws_identitystore_user"` no Terraform.
4. **Modelar o acesso via Permission Set do IAM Identity Center**, com a mesma policy gerenciada `PowerUserAccess` já usada antes (`aws_ssoadmin_permission_set` + `aws_ssoadmin_managed_policy_attachment` + `aws_ssoadmin_account_assignment`), preservando o mesmo nível de privilégio e a mesma exclusão de IAM/Organizations do desenho original.
5. **Manter a separação de módulos do ADR 002**: `terraform/bootstrap-iam/` continua admin-only (aplicado via CloudShell/root), já que os recursos `aws_ssoadmin_*`/`aws_identitystore_*` também não estão cobertos pela `PowerUserAccess` do operador diário. `terraform/bootstrap/` continua de uso diário, sem mudanças.
6. **Profile local `cloudlab` passa a usar `sso-session`** (mesmo padrão já em uso neste ambiente para outro projeto/conta), autenticando via `aws sso login --profile cloudlab` em vez de access key estática gravada em `~/.aws/credentials`.

### Alternativas consideradas

- **Manter o `aws_iam_user` como break-glass, sem access key ativa:** descartada — adicionaria um recurso e uma exceção a mais para documentar e manter coerente, sem benefício real num projeto de operador único onde o root via CloudShell já cobre qualquer cenário de recuperação.
- **Criar o usuário do Identity Center via Terraform (`aws_identitystore_user`):** descartada — não dispara o fluxo de convite/definição de senha da AWS, tornando o primeiro acesso mais frágil do que criar uma única vez pelo console.

## Consequências

- Nenhuma credencial estática de operador humano existe mais na conta; a autenticação local expira sozinha a cada sessão (`session_duration = "PT4H"` no permission set).
- Habilitar o Identity Center e criar o usuário seguem sendo passos manuais únicos por conta — documentados em [`docs/runbooks/aws-account-bootstrap.md`](../runbooks/aws-account-bootstrap.md) — coerente com o mesmo tipo de exceção já aceita para a criação da conta/root no ADR 002.
- Qualquer mudança futura de acesso (novo permission set, novo usuário) continua exigindo sessão root/CloudShell em `terraform/bootstrap-iam/`, sem alteração de fluxo em relação ao ADR 002.
- A pendência registrada no `CLAUDE.md` sobre migração para SSO fica resolvida.
