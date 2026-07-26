# Runbook — Backend remoto do Terraform

> Ver decisão em [`docs/adr/001-terraform-state-backend.md`](../../adr/001-terraform-state-backend.md).

## Criação do bucket

O bucket de state é criado junto com o bootstrap de conta/IAM — ver [`docs/runbooks/bootstrap/aws-account-bootstrap.md`](aws-account-bootstrap.md) (passos 4-7). Este runbook cobre apenas o **uso** do backend já criado.

## Usar o backend em um novo ambiente

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
aws s3api get-bucket-versioning --profile cloudlab --bucket minitube-tfstate-<account-id>
aws s3api get-bucket-encryption --profile cloudlab --bucket minitube-tfstate-<account-id>
aws s3api get-public-access-block --profile cloudlab --bucket minitube-tfstate-<account-id>
```

Confirmar: versionamento `Enabled`, criptografia `AES256`, todas as 4 flags de bloqueio público `true`.

## Rollback

Este bucket tem `prevent_destroy = true` propositalmente (ver ADR 001). Para destruí-lo de fato (ex.: encerrando o projeto por completo), é preciso remover essa trava no código, commitar a mudança e só então rodar `terraform destroy` — nunca via console.
