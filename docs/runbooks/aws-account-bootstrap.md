# Runbook — Bootstrap de conta AWS nova

> Procedimento único por conta AWS. Ver decisão em [`docs/adr/002-aws-account-and-iam-bootstrap.md`](../adr/002-aws-account-and-iam-bootstrap.md) e [`docs/adr/003-cloudlab-operator-sso-migration.md`](../adr/003-cloudlab-operator-sso-migration.md).

## Passo 1 — Conta e root (manual, fora de qualquer automação)

1. Criar e-mail dedicado (ex.: `alisson.cloudlab@gmail.com`).
2. Criar a conta AWS em https://aws.amazon.com/pt/ com esse e-mail.
3. Login como root → definir senha forte → guardar em gerenciador de senhas.
4. Ativar MFA no root (console → Security credentials → Assign MFA device).

## Passo 2 — Abrir o CloudShell

No console AWS, clicar no ícone do CloudShell (topo da página). A sessão herda as credenciais temporárias do login root — nenhuma access key de root é criada.

⚠️ **Configurar cache de provider compartilhado antes de qualquer `terraform init`.** O CloudShell tem apenas 1 GB de storage persistente em `$HOME` (limite da AWS, não do projeto). Os passos 6 e 7 rodam `terraform init` em dois diretórios diferentes (`bootstrap-iam/` e `bootstrap/`) na mesma sessão — sem cache compartilhado, cada um baixa sua própria cópia do provider `hashicorp/aws` (~500 MB) e o disco enche, causando `Error: Failed to install provider ... no space left on device`. Evite isso configurando:

```bash
mkdir -p ~/.terraform.d/plugin-cache
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
```

antes do primeiro `terraform init` da sessão. Assim o provider é baixado uma única vez e reaproveitado por todos os módulos.

## Passo 3 — Clonar o repositório

```bash
gh auth login   # necessário se o repositório estiver privado (device flow, sem chave SSH)
gh repo clone alisson92/minitube
cd minitube
git checkout feat/terraform-bootstrap   # ou main, se já mergeado
```

## Passo 4 — Habilitar o IAM Identity Center (manual, console)

Ativação de serviço em nível de conta — a AWS não expõe isso via Terraform:

1. Console AWS → IAM Identity Center → "Enable".
2. Confirmar que a fonte de identidade fica como "Identity Center directory" (loja de identidade interna, sem AD/IdP externo).
3. Em "Settings", anotar a **AWS access portal URL** (`https://<subdomínio>.awsapps.com/start`) — será usada no passo 8.

## Passo 5 — Criar o usuário operador no Identity Center (manual, console)

1. Console → IAM Identity Center → Users → Add user.
2. Username/e-mail: `alisson.cloudlab@gmail.com`.
3. Aceitar o e-mail de convite e definir senha + MFA.

Criar o usuário via Terraform (`aws_identitystore_user`) não dispara esse fluxo de convite/ativação — por isso esse passo é manual, uma única vez por conta.

## Passo 6 — Aplicar `bootstrap-iam` (permission set do operador)

Cria o permission set `cloudlab-operator` e a atribuição de conta para o usuário criado no passo 5 — precisa rodar com a sessão root/CloudShell, pois os recursos `aws_ssoadmin_*`/`aws_identitystore_*` não estão cobertos pela `PowerUserAccess` do operador diário:

```bash
cd terraform/bootstrap-iam
terraform init
terraform plan       # revisar: permission set + managed policy attachment + account assignment
terraform apply       # confirmar manualmente (yes)
```

Nenhum valor sensível é gerado neste passo — sem access key para copiar.

## Passo 7 — Aplicar `bootstrap` (bucket de state)

Ainda no CloudShell, com a mesma sessão root (o `cloudlab-operator` ainda não tem o bucket para si mesmo usar depois):

```bash
cd ../bootstrap
terraform init
terraform plan       # revisar: bucket S3 versionado/criptografado/sem acesso público
terraform apply       # confirmar manualmente (yes)
```

## Passo 8 — Configurar o profile local via SSO

Na sua máquina local (não no CloudShell), criar um `sso-session` dedicado à conta `cloudlab` em `~/.aws/config`:

```ini
[profile cloudlab]
sso_session = cloudlab
sso_account_id = <account id da conta cloudlab>
sso_role_name  = cloudlab-operator
region = us-east-1
output = json

[sso-session cloudlab]
sso_start_url = https://<subdomínio-do-passo-4>.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

⚠️ **Antes de testar, remova qualquer access key estática antiga de `~/.aws/credentials` para o profile `cloudlab`** (do `aws configure` usado antes desta migração). O AWS CLI/SDK dá prioridade a `aws_access_key_id`/`aws_secret_access_key` de `~/.aws/credentials` sobre o `sso_session` de `~/.aws/config` quando os dois existem para o mesmo profile — se a chave antiga (já destruída no passo 6) ficar para trás, o resultado é `InvalidClientTokenId: The security token included in the request is invalid`, mesmo com o SSO configurado certo.

Depois:

```bash
aws sso login --profile cloudlab
aws sts get-caller-identity --profile cloudlab   # deve retornar o assumed-role do permission set
```

Usar `AWS_PROFILE=cloudlab` (ou `--profile cloudlab`) em todos os comandos Terraform/AWS CLI do projeto daqui em diante. A sessão expira sozinha — repetir `aws sso login --profile cloudlab` quando expirar.

## Passo 9 — Conectar o Terraform local ao backend remoto

Em `terraform/bootstrap/` local (o `backend.tf` já aponta pro bucket criado no passo 7):

```bash
AWS_PROFILE=cloudlab terraform init
AWS_PROFILE=cloudlab terraform plan   # deve dar "No changes"
```

`terraform/bootstrap-iam/` **não** roda localmente com `cloudlab-operator` — ver regra permanente abaixo.

## Regra permanente

`terraform/bootstrap-iam/` só pode ser planejado/aplicado com sessão root/CloudShell — a `PowerUserAccess` do `cloudlab-operator` exclui IAM de propósito, e os recursos de IAM Identity Center exigem permissões que também não estão nessa policy. Qualquer mudança futura ali (novo permission set, novo usuário) repete os passos 4-6. Todo o resto do projeto — bucket de state, VPC, EKS, CloudFront, DNS — roda com `cloudlab-operator` via SSO, local, sem console.
