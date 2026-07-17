# Runbook — Bootstrap do backend remoto do Terraform

> Procedimento único, executado uma vez por conta AWS. Ver decisão em [`docs/adr/001-terraform-state-backend.md`](../adr/001-terraform-state-backend.md).

## Quando executar

Apenas quando o bucket de state (`minitube-tfstate-<account-id>`) ainda não existe na conta AWS de destino — normalmente, uma única vez na vida do projeto.

## Pré-requisitos

- AWS CLI configurado com credenciais de um usuário IAM (nunca root) com permissão para criar/gerenciar bucket S3.
- Terraform `~> 1.14` instalado (necessário suporte a `use_lockfile`, disponível desde a 1.10).

## Passo 1 — Criar o bucket com backend local

```bash
cd terraform/bootstrap
terraform fmt -check          # formatação consistente
terraform init                # backend local, propositalmente — o bucket ainda não existe
terraform validate
terraform plan                # revisar: deve mostrar apenas os recursos do bucket de state
```

Revisar o plano manualmente antes de prosseguir — não usar `-auto-approve`.

```bash
terraform apply               # confirmar manualmente (yes)
```

Isso cria o bucket `minitube-tfstate-<account-id>` com versionamento, criptografia, bloqueio de acesso público e política TLS-only.

## Passo 2 — Migrar o state do bootstrap para dentro do próprio bucket

Depois do `apply`, o state do bootstrap ainda está em `terraform/bootstrap/terraform.tfstate` (local). Para não deixar esse arquivo como o único registro do bootstrap:

1. Adicionar em `terraform/bootstrap/backend.tf`:

   ```hcl
   terraform {
     backend "s3" {
       bucket       = "minitube-tfstate-<account-id>"  # valor do output state_bucket_name
       key          = "bootstrap/terraform.tfstate"
       region       = "us-east-1"
       use_lockfile = true
       encrypt      = true
     }
   }
   ```

2. Rodar a migração:

   ```bash
   terraform init -migrate-state
   ```

3. Confirmar quando solicitado. O Terraform copia o state local para o bucket.
4. Validar que o state remoto está correto: `terraform plan` deve mostrar "No changes".

## Passo 3 — Usar o backend nos demais ambientes

Em cada novo ambiente (ex.: `terraform/envs/lab/backend.tf`):

```hcl
terraform {
  backend "s3" {
    bucket       = "minitube-tfstate-<account-id>"
    key          = "envs/lab/terraform.tfstate"   # key única por ambiente
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
```

Cada ambiente usa uma `key` própria dentro do mesmo bucket — não há necessidade de um bucket por ambiente.

## Verificação

```bash
aws s3api get-bucket-versioning --bucket minitube-tfstate-<account-id>
aws s3api get-bucket-encryption --bucket minitube-tfstate-<account-id>
aws s3api get-public-access-block --bucket minitube-tfstate-<account-id>
```

Confirmar: versionamento `Enabled`, criptografia `AES256`, todas as 4 flags de bloqueio público `true`.

## Rollback

Este bucket tem `prevent_destroy = true` propositalmente (ver ADR 001). Para destruí-lo de fato (ex.: encerrando o projeto por completo), é preciso remover essa trava no código, commitar a mudança e só então rodar `terraform destroy` — nunca via console.
