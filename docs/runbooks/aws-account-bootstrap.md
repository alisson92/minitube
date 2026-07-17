# Runbook — Bootstrap de conta AWS nova

> Procedimento único por conta AWS. Ver decisão em [`docs/adr/002-aws-account-and-iam-bootstrap.md`](../adr/002-aws-account-and-iam-bootstrap.md).

## Passo 1 — Conta e root (manual, fora de qualquer automação)

1. Criar e-mail dedicado (ex.: `alisson.cloudlab@gmail.com`).
2. Criar a conta AWS em https://aws.amazon.com/pt/ com esse e-mail.
3. Login como root → definir senha forte → guardar em gerenciador de senhas.
4. Ativar MFA no root (console → Security credentials → Assign MFA device).

## Passo 2 — Abrir o CloudShell

No console AWS, clicar no ícone do CloudShell (topo da página). A sessão herda as credenciais temporárias do login root — nenhuma access key de root é criada.

## Passo 3 — Clonar o repositório

```bash
gh auth login   # necessário se o repositório estiver privado (device flow, sem chave SSH)
gh repo clone alisson92/minitube
cd minitube
git checkout feat/terraform-bootstrap   # ou main, se já mergeado
```

## Passo 4 — Aplicar `bootstrap-iam` (usuário operacional)

Cria o `cloudlab-operator` — precisa rodar com a sessão root/CloudShell, é o único jeito de criar a primeira identidade da conta:

```bash
cd terraform/bootstrap-iam
terraform init
terraform plan       # revisar: usuário + policy PowerUserAccess + access key
terraform apply       # confirmar manualmente (yes)
terraform output -raw operator_access_key_id
terraform output -raw operator_secret_access_key
```

Copiar os dois valores para um gerenciador de senhas. Não colar em chat, issue ou qualquer lugar não seguro.

## Passo 5 — Aplicar `bootstrap` (bucket de state)

Ainda no CloudShell, com a mesma sessão root (o `cloudlab-operator` ainda não tem o bucket para si mesmo usar depois):

```bash
cd ../bootstrap
terraform init
terraform plan       # revisar: bucket S3 versionado/criptografado/sem acesso público
terraform apply       # confirmar manualmente (yes)
```

## Passo 6 — Configurar o profile local

Na sua máquina local (não no CloudShell):

```bash
aws configure --profile cloudlab
# AWS Access Key ID: <valor do passo 4>
# AWS Secret Access Key: <valor do passo 4>
# Default region: us-east-1
```

Usar `AWS_PROFILE=cloudlab` (ou `--profile cloudlab`) em todos os comandos Terraform/AWS CLI do projeto daqui em diante.

## Passo 7 — Conectar o Terraform local ao backend remoto

Em `terraform/bootstrap/` local (o `backend.tf` já aponta pro bucket criado no passo 5):

```bash
AWS_PROFILE=cloudlab terraform init
AWS_PROFILE=cloudlab terraform plan   # deve dar "No changes"
```

`terraform/bootstrap-iam/` **não** roda localmente com `cloudlab-operator` — ver regra permanente abaixo.

## Regra permanente

`terraform/bootstrap-iam/` só pode ser planejado/aplicado com sessão root/CloudShell — a `PowerUserAccess` do `cloudlab-operator` exclui IAM de propósito, então ele nem consegue ler o próprio usuário. Qualquer mudança futura ali (nova policy, novo usuário) repete os passos 2-4. Todo o resto do projeto — bucket de state, VPC, EKS, CloudFront, DNS — roda com `cloudlab-operator`, local, sem console.
