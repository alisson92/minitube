# Runbook — Validação funcional do budget alert

> Estabelece o padrão de "validação funcional pós-apply" descrito em [`docs/engineering-standards.md`](../engineering-standards.md#11-validação-funcional-pós-apply). Ver também [`docs/adr/005-budget-alert-persistence.md`](../adr/005-budget-alert-persistence.md).

## Por que isso existe

`terraform apply` sem erro e `aws budgets describe-budgets` mostrando o recurso criado provam que o budget **existe com os atributos esperados** — não provam que ele **notifica corretamente**. A pergunta que importa: o limite mensal está certo, e as duas notificações (80% projetado, 100% real) estão configuradas com o e-mail certo?

## Limitação conhecida: não dá para forçar o disparo real do alerta

A AWS Budgets recalcula gasto real e projetado **no seu próprio schedule** (não instantaneamente após `apply` ou mudança de configuração — tipicamente algumas horas). Não existe um comando para forçar essa reavaliação sob demanda. Por isso, `scripts/validate-budget.sh` valida **configuração** via API (`describe-budgets`, `describe-notifications-for-budget`, `describe-subscribers-for-notification`), não o disparo real do e-mail de alerta. Confirmar que o alerta realmente dispara só é possível organicamente: observar a caixa de entrada (`alisson.cloudlab@gmail.com`) ao longo do uso normal da conta, quando o gasto de fato cruzar 80%/100% do limite.

## Como funciona o script

- **Checagens executadas:**
  1. O budget (`minitube-monthly-cost-alert`) existe na conta.
  2. O limite é `10 USD`/`MONTHLY` (valor lido de `var.budget_limit_usd`).
  3. A notificação `FORECASTED` em 80% (`GREATER_THAN`) está configurada.
  4. A notificação `ACTUAL` em 100% (`GREATER_THAN`) está configurada.
  5. O e-mail assinante (`alisson.cloudlab@gmail.com`) está de fato na lista de subscribers da notificação de 100%.
- Não cria nem destrói nenhum recurso — só leitura via `aws budgets describe-*`, então não precisa de `trap` de cleanup.

## Aplicar e rodar o teste

```bash
# Sessão root/CloudShell — bootstrap-iam é admin-only (ver ADR 002/003)
cd terraform/bootstrap-iam
terraform init
terraform plan     # revisar: 1 recurso novo (aws_budgets_budget), nada mais muda
terraform apply

./scripts/validate-budget.sh
```

Dependências: `aws` CLI, `jq`, `terraform`.

## Leitura esperada do output

```
PASS: budget 'minitube-monthly-cost-alert' exists in account 479213212405
PASS: budget limit is 10.0 USD / MONTHLY
PASS: 80% FORECASTED notification is configured
PASS: 100% ACTUAL notification is configured
PASS: notifications subscribe 'alisson.cloudlab@gmail.com'
=== All checks passed: budget alert is configured as expected. ===
NOTE: this validates configuration only. AWS Budgets recalculates spend
on its own schedule (not instantly), so a real alert firing can only be
confirmed organically over time -- see docs/runbooks/validate-budget-alert.md.
```

Código de saída `0` quando tudo passa, `1` se qualquer checagem falhar.

## Alterar o limite ou o e-mail

Editar `budget_limit_usd`/`budget_notification_email` em `terraform/bootstrap-iam/variables.tf` (ou passar via `-var`), depois repetir o fluxo `plan` → `apply` → `validate-budget.sh` acima, sempre via CloudShell/sessão root.

## Persistência

O budget alert **não** é destruído entre sessões — vive em `terraform/bootstrap-iam/`, junto com as roles IAM e o permission set do operador, fora do ciclo efêmero de `terraform/envs/lab/` (ver ADR 005). Nenhuma ação é necessária ao encerrar uma sessão de teste de VPC/EKS.
