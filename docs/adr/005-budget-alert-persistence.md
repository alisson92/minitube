# 005 — Persistência do budget alert em `bootstrap-iam`

## Status

Aceito

## Contexto

O último entregável pendente da Fase 1 é o budget alert (`CLAUDE.md`, seção "Fases do projeto"). Seu propósito é notificar sobre gasto inesperado na conta AWS (`479213212405`) — inclusive infraestrutura esquecida de pé por engano, fora do ciclo normal `apply`/`destroy` de `terraform/envs/lab/`. Isso levanta a mesma pergunta já respondida pelos ADRs 001, 002 e 004 para outros recursos: o que deve sobreviver entre sessões, apesar do princípio de infraestrutura efêmera do projeto?

## Decisão

O budget alert (`aws_budgets_budget`) vive em `terraform/bootstrap-iam/`, junto com o bucket de state e as roles IAM — persistente, aplicado uma vez, fora do ciclo `apply`/`destroy` de `envs/lab/`. Cobre o custo total da conta (sem `cost_filter`), com duas notificações por e-mail direto (`subscriber_email_addresses`, sem tópico SNS): 80% do limite mensal (`FORECASTED`, alerta preventivo) e 100% (`ACTUAL`, limite já estourado). Limite mensal: **10 USD**. E-mail: `alisson.cloudlab@gmail.com` (mesmo usuário SSO do operador diário).

## Alternativas consideradas

- **Colocar em `terraform/envs/lab/`:** descartada. Se o budget fosse destruído a cada sessão junto com a VPC/EKS, perderia exatamente a cobertura que mais importa — detectar gasto quando ninguém está olhando ativamente para a conta, entre sessões de teste.
- **Tópico SNS em vez de e-mail direto na notificação:** descartada. O recurso `aws_budgets_budget` aceita `subscriber_email_addresses` nativamente, sem exigir confirmação de assinatura (diferente de uma subscription SNS). Um tópico SNS só se justificaria para fan-out multi-canal (ex.: Slack via Lambda) — não é o caso hoje. Pode ser adicionado depois sem quebrar o que existe.
- **Módulo `terraform/bootstrap-budget/` dedicado:** descartada. A API de AWS Budgets não depende das restrições de IAM que forçam `bootstrap-iam/` a ser admin-only (PowerUserAccess não bloqueia `budgets:*`), mas criar um terceiro módulo só para um único recurso seria over-engineering. Reaproveitar o fluxo já estabelecido (CloudShell/sessão root) para `bootstrap-iam/` mantém um único lugar mental para "coisas persistentes e de baixa frequência de mudança".

## Consequências

- O budget alert nunca é destruído entre sessões; qualquer alteração de limite ou e-mail passa pelo fluxo admin-only já existente (CloudShell/sessão root) de `bootstrap-iam/`.
- AWS Budgets tem lag de avaliação (a AWS recalcula gasto real/projetado periodicamente, não instantaneamente após `apply` ou mudança de configuração — tipicamente a cada poucas horas). A validação funcional pós-apply (`scripts/validate-budget.sh`, `docs/runbooks/validate-budget-alert.md`) confirma a **configuração** via API (`describe-budgets`, `describe-notifications-for-budget`), não o disparo real do alerta — isso só pode ser confirmado organicamente, observando a caixa de entrada ao longo do uso normal da conta.
- Fecha o critério de conclusão da Fase 1: todos os entregáveis da tabela de fases do `CLAUDE.md` passam a estar implementados e validados.
