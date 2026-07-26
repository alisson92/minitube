# 001 — Backend remoto do Terraform: bucket S3 único com lock nativo

## Status

Aceito

## Contexto

Todos os ambientes do MiniTube (`terraform/envs/lab/...` e futuros) precisam de um backend remoto de state, com lock, para permitir trabalho seguro (mesmo que hoje seja um único operador) e recuperação em caso de falha. Esse backend não pode ser criado pelo próprio ambiente que vai usá-lo — é o clássico problema de "ovo e galinha" do bootstrap de Terraform.

Historicamente, a recomendação da HashiCorp para lock de state em S3 era um bucket S3 (state) + uma tabela DynamoDB dedicada (lock via `LockID`). Desde o Terraform 1.10, o backend `s3` suporta **lock nativo** via `use_lockfile = true`, usando o próprio bucket S3 com escrita condicional (`If-None-Match`), sem depender de DynamoDB.

## Decisão

1. Criar um único bucket S3 (`terraform/bootstrap/`) para hospedar o state de todos os ambientes do projeto: `minitube-tfstate-<account-id>`.
2. Usar **lock nativo do S3** (`use_lockfile = true` no bloco `backend "s3"` de cada ambiente), e não uma tabela DynamoDB. Motivos:
   - É a orientação atual da documentação oficial da HashiCorp para novos backends S3.
   - Evita um recurso AWS adicional (tabela + eventual IAM extra) para um projeto de laboratório de custo controlado.
   - Reduz a superfície do bootstrap a um único recurso principal.
3. O bucket é criado com:
   - Versionamento habilitado (recuperação/auditoria de states anteriores).
   - Criptografia SSE-S3 (`AES256`) por padrão — sem custo de KMS.
   - Bloqueio total de acesso público (`aws_s3_bucket_public_access_block`).
   - Política negando qualquer acesso fora de TLS (`aws:SecureTransport = false` → `Deny`).
   - Expiração de versões não-correntes após 90 dias, para não acumular custo de storage indefinidamente.
   - `lifecycle { prevent_destroy = true }`, para evitar destruição acidental.
4. O bootstrap em si usa **backend local** no primeiro `apply` (não há onde mais guardar o state antes do bucket existir). Depois de criado, um bloco `backend "s3"` é adicionado apontando para o próprio bucket, e `terraform init -migrate-state` migra o state do bootstrap para dentro dele — o bootstrap passa a gerenciar seu próprio state remotamente. Procedimento documentado em `docs/runbooks/bootstrap/bootstrap-remote-backend.md`.

### Alternativa considerada: bucket S3 + tabela DynamoDB

Descartada para este projeto por adicionar um recurso e uma dependência de IAM extra sem benefício prático em um cenário de operador único. Vale registrar que essa é a abordagem tradicional (e ainda amplamente documentada, inclusive no conteúdo da certificação Terraform Associate) — pode ser reavaliada se o projeto evoluir para múltiplos operadores/CI com necessidade de auditoria de lock mais granular.

## Consequências

- **Exceção ao princípio de infraestrutura efêmera do projeto** (ver `CLAUDE.md`): o bucket de state é o único recurso que precisa persistir entre sessões — sem ele, não há onde os ambientes futuros gravarem/recuperarem seu histórico de state. Essa persistência é intencional e está registrada na seção "Estado atual" do `CLAUDE.md`, de forma análoga à decisão prevista para a zona DNS na Fase 4.
- Qualquer ambiente novo (`terraform/envs/<env>/backend.tf`) deve referenciar este bucket com `use_lockfile = true`, sem depender de uma tabela DynamoDB.
- Destruir este bucket exige remover manualmente o `prevent_destroy` — é uma barreira deliberada contra acidentes, não uma trava permanente.
