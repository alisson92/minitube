# Runbook — Acesso à UI do ArgoCD

## Por que a senha muda a cada sessão

O `terraform/envs/lab/argocd.tf` não define `configs.secret.argocdServerAdminPassword` nos values do chart `argo-cd` — de propósito, para não commitar segredo nenhum no repositório. Sem esse valor, o próprio chart gera uma senha aleatória no primeiro deploy e grava no Secret `argocd-initial-admin-secret` (namespace `argocd`).

Como `envs/lab` é recriado do zero em toda sessão (princípio de [infraestrutura efêmera](../../CLAUDE.md#princípios-inegociáveis)), o ArgoCD também é reinstalado do zero — logo, uma senha nova é gerada a cada vez. Não há como "fixar" essa senha sem passar a commitá-la (ou movê-la para um secret manager), o que não vale a pena para um ambiente que só existe algumas horas por sessão.

## Comando

Pré-requisito: `kubectl` configurado contra o cluster da sessão atual.

```bash
# 1. Configura o kubeconfig (se ainda não tiver feito nesta sessão)
AWS_PROFILE=cloudlab aws eks update-kubeconfig --name minitube-lab --region us-east-1

# 2. Usuário sempre é "admin"; a senha sai do Secret gerado pelo chart
AWS_PROFILE=cloudlab kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

- **URL:** `https://argocd.minitube.projetodevops.com.br`
- **Usuário:** `admin`
- **Senha:** saída do comando acima

## Nota sobre rotação

Esse é o Secret *inicial* — ele continua valendo até alguém trocar a senha pela UI/CLI do ArgoCD (`argocd account update-password`), momento em que o chart o remove automaticamente (comportamento documentado do `argo-cd` Helm chart). Como o ambiente é destruído e recriado a cada sessão, essa rotação nunca chega a importar na prática aqui — mas vale saber para não estranhar se um dia a senha antiga parar de funcionar sem o ambiente ter sido recriado.
