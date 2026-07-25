# Runbook — Acesso à UI do ArgoCD

## Como a senha é definida

`terraform/envs/lab/argocd.tf` gera a senha do `admin` via `random_password.argocd_admin` e injeta o hash bcrypt correspondente diretamente nos values do chart `argo-cd` (`configs.secret.argocdServerAdminPassword`/`argocdServerAdminPasswordMtime`, via `terraform_data.argocd_admin_password_hash`) — mesmo mecanismo já usado para a senha do Grafana (ADR 011, decisão 12). O valor em texto plano nunca é commitado: fica só no state do Terraform (backend remoto S3), lido via `terraform output`.

Pré-seedar a senha assim faz o ArgoCD **nunca** criar o Secret `argocd-initial-admin-secret` (esse secret só é gerado pelo chart quando nenhuma senha de admin já existe em `argocd-secret`) — por isso o comando antigo (`kubectl get secret argocd-initial-admin-secret`) não funciona mais; use sempre o `terraform output` abaixo.

Como `envs/lab` é recriado do zero em toda sessão, a senha muda a cada `terraform apply` (nova execução de `random_password.argocd_admin`) — não existe um `admin/admin` fixo entre sessões, só dentro da mesma.

## Comando

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform output -raw argocd_admin_password && echo
```

- **URL:** `https://argocd.minitube.projetodevops.com.br`
- **Usuário:** `admin`
- **Senha:** saída do comando acima

## Nota sobre rotação

Trocar a senha pela UI/CLI do ArgoCD (`argocd account update-password`) sobrescreve o hash em `argocd-secret` diretamente no cluster — o valor do `terraform output` fica desatualizado a partir daí (o Terraform não sabe da troca, e um `terraform apply` sem mudança nenhuma no state não reverte, graças ao `lifecycle.ignore_changes` em `terraform_data.argocd_admin_password_hash`). Como o ambiente é destruído e recriado a cada sessão, isso raramente chega a importar na prática — mas vale saber para não estranhar se a senha do `terraform output` parar de bater com a que está de fato ativa.
