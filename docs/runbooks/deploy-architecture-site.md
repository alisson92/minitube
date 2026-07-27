# Runbook — Deploy da página de arquitetura

> Atualiza o conteúdo de `https://system-design.minitube.projetodevops.com.br`. Não confundir com o runbook principal (`run-the-project.md`) — este recurso vive em `terraform/bootstrap/`, persistente, fora do ciclo `apply`/`destroy` diário de `envs/lab`. Ver [ADR 017](../adr/017-persistent-architecture-showcase-site.md).

## Quando rodar

Sempre que `site/architecture/index.html` mudar. A infraestrutura (`terraform/bootstrap/architecture-site.tf`) só precisa de `apply` uma vez (ou quando o próprio recurso Terraform mudar) — conteúdo e infraestrutura são deploys separados de propósito.

## Primeira vez (só quando a infraestrutura ainda não existe)

```bash
cd terraform/bootstrap
terraform plan   # revisar antes de aplicar, mesmo sendo um módulo persistente
terraform apply
```

## Deploy de conteúdo (toda vez que a página mudar)

```bash
cd terraform/bootstrap
AWS_PROFILE=cloudlab ./scripts/deploy-architecture-site.sh
```

O script lê `bucket`/`distribution_id` via `terraform output` (nunca hardcoded), sincroniza `site/architecture/` para o S3 e invalida o cache do CloudFront — a mudança fica visível em segundos, sem esperar o TTL do cache.

## Validação funcional

Depois do primeiro `apply` + primeiro deploy:

```bash
curl -sI https://system-design.minitube.projetodevops.com.br | head -5
```

Esperado: `HTTP/2 200`, certificado válido (sem erro do `curl`), `content-type: text/html`. Abrir no navegador para conferir visualmente — "apply sem erro" não prova que a página renderiza certo (`docs/engineering-standards.md` §11).

## Notas

- `terraform/bootstrap/` nunca é destruído — não há runbook de "destroy" para este recurso.
- O conteúdo (`site/architecture/index.html`) não é gerenciado pelo Terraform — mudanças nele exigem rodar o script de deploy, não `terraform apply`.
