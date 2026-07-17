# Runbook — Bootstrap de conta AWS nova

> Procedimento único por conta AWS. Ver decisão em [`docs/adr/002-aws-account-and-iam-bootstrap.md`](../adr/002-aws-account-and-iam-bootstrap.md).

## Passo 1 — Conta e root (manual, fora de qualquer automação)

1. Criar e-mail dedicado (ex.: `alisson.cloudlab@gmail.com`).
2. Criar a conta AWS em https://aws.amazon.com/pt/ com esse e-mail.
3. Login como root → definir senha forte → guardar em gerenciador de senhas.
4. Ativar MFA no root (console → Security credentials → Assign MFA device).

## Passo 2 — Abrir o CloudShell

No console AWS, clicar no ícone do CloudShell (topo da página). A sessão herda as credenciais temporárias do login root — nenhuma access key de root é criada.

## Passo 3 — Rodar o bootstrap dentro do CloudShell

O repositório é privado — autenticar o `gh` uma vez (device flow, sem precisar de chave SSH):

```bash
gh auth login   # escolher GitHub.com → HTTPS → login via navegador
gh repo clone alisson92/minitube
cd minitube/terraform/bootstrap
git checkout feat/terraform-bootstrap
terraform init
terraform plan       # revisar: bucket de state + usuário cloudlab-operator + policy + access key
terraform apply       # confirmar manualmente (yes)
```

## Passo 4 — Recuperar as credenciais do operador

Ainda no CloudShell:

```bash
terraform output -raw operator_access_key_id
terraform output -raw operator_secret_access_key
```

Copiar os dois valores para um gerenciador de senhas. Não colar em chat, issue ou qualquer lugar não seguro.

## Passo 5 — Configurar o profile local

Na sua máquina local (não no CloudShell):

```bash
aws configure --profile cloudlab
# AWS Access Key ID: <valor do passo 4>
# AWS Secret Access Key: <valor do passo 4>
# Default region: us-east-1
```

Usar `AWS_PROFILE=cloudlab` (ou `--profile cloudlab`) em todos os comandos Terraform/AWS CLI do projeto daqui em diante.

## Passo 6 — Migrar o state do bootstrap

Com `AWS_PROFILE=cloudlab`, seguir o [runbook de migração de backend](bootstrap-remote-backend.md) a partir do Passo 2 (adicionar `backend.tf` e rodar `terraform init -migrate-state`).

## Regra permanente

Depois deste bootstrap, **root e CloudShell só voltam a ser usados para mudanças de IAM** (novo usuário, nova policy). Todo o resto do projeto — VPC, EKS, CloudFront, DNS — roda com `cloudlab-operator`, local, sem console.
