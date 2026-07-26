# Fase 3 — GitOps

> Retrospecto da fase, escrito ao final dela. Não repete o conteúdo de ADRs e runbooks — linka para eles. Serve como insumo para a documentação final do projeto (ver `CLAUDE.md`, seção "Estrutura do repositório").

## Objetivo da fase

Instalar o ArgoCD e fazer ele assumir a reconciliação de `gitops/app/` (e preparar `gitops/platform/` para a Fase 5), encerrando a exceção temporária de `kubectl apply -k` manual aberta na Fase 2. Critério de conclusão (`CLAUDE.md`): *"Nenhum `kubectl apply` manual — todo deploy sai do Git."*

## O que foi entregue

| Entregável | Onde vive | Persistente ou efêmero |
| --- | --- | --- |
| ArgoCD (chart `argo-cd`) | `terraform/envs/lab/argocd.tf` + `values/argocd.yaml` | Efêmero — instalado a cada `terraform apply` de `envs/lab` |
| Bootstrap declarativo das Applications raiz (chart `argocd-apps`) | `terraform/envs/lab/argocd.tf` | Efêmero |
| `AppProject minitube-platform` | `terraform/envs/lab/argocd.tf` (via `argocd-apps`) | Efêmero |
| Credencial Git (deploy key SSH) | `kubernetes_secret_v1.argocd_repo_credentials` | Efêmero — chave gerada fora do repo, cadastrada como Deploy Key no GitHub |
| `gitops/app/` reconciliado pelo ArgoCD (não mais `kubectl apply -k`) | `gitops/app/` | — |
| `gitops/platform/` (placeholder para Fase 5) | `gitops/platform/README.md` | — |
| 2 novas grants de IAM no operador (`PassEksRoles` +1 action, `ReadEksServiceLinkedRoles` nova) | `terraform/bootstrap-iam/main.tf` | Persistente |

## Decisões de arquitetura (ADRs)

- **[ADR 007](../adr/007-argocd-gitops-bootstrap.md)** — decisão central da fase. Cobre: instalação do ArgoCD via `helm_release` Terraform (não `helm install` manual); bootstrap das Applications raiz via chart `argocd-apps` (sem `kubectl apply` nem para isso); `gitops/platform/` criado agora como placeholder, com `AppProject` declarado via Terraform para evitar problema de ovo-e-galinha; deploy key SSH somente-leitura para o repositório privado; Dex/notifications desabilitados (YAGNI); acesso à UI só via port-forward nesta fase; self-management do ArgoCD (app-in-app) avaliado e adiado; e os bugs reais descritos abaixo.
- **[ADR 006](../adr/006-app-irsa-and-job-orchestration.md)** ganhou uma nota de atualização (item 7): o `kubectl apply -k gitops/app/` manual deixou de ser necessário a partir desta fase.

## Bugs reais encontrados e corrigidos

Como nas fases anteriores, nenhum destes apareceu antes de um `terraform apply`/validação real contra a AWS:

1. **Access entry duplicado.** Como o `cloudlab-operator` (não CloudShell/root, ao contrário das Fases 1–2) foi quem chamou `CreateCluster` nesta sessão, `bootstrap_cluster_creator_admin_permissions=true` (ADR 004) criou automaticamente um access entry + `AmazonEKSClusterAdminPolicy` para esse principal — em conflito com o `aws_eks_access_entry.operator` explícito que o Terraform tentava criar por cima (`ResourceInUseException`). Resolvido com `terraform import` do recurso já existente para o state, sem nenhum comando `aws eks` manual fora do Terraform.
2. **`iam:ListAttachedRolePolicies` faltando para `CreateNodegroup`.** O provider AWS valida as managed policies já anexadas à role do node antes de criar o node group — ação não coberta pela `Statement` `PassEksRoles` original (só tinha `GetRole`/`PassRole`). Corrigido acrescentando a action à mesma `Statement`, aplicado via CloudShell/root em `terraform/bootstrap-iam/`.
3. **`iam:GetRole` faltando nos service-linked roles do EKS.** Mesmo após corrigir o bug 2, `CreateNodegroup` falhou de novo: também confirma que `AWSServiceRoleForAmazonEKSNodegroup` já existe via `iam:GetRole` direto nesse ARN — não coberto por nenhuma `Statement` existente (que só cobriam as roles do cluster/node, não os SLRs). Corrigido com uma `Statement` nova, `ReadEksServiceLinkedRoles`, escopada aos dois SLRs do EKS.
4. **`global.additionalLabels` sobrescrevendo o `part-of` interno do ArgoCD.** O bug mais custoso de diagnosticar da fase: `values/argocd.yaml` definia `global.additionalLabels: {app.kubernetes.io/part-of: minitube}` como rótulo de agrupamento, mas essa mesma chave já é usada pelo chart (`part-of: argocd`) e lida pelo próprio `argocd-server`/`argocd-application-controller` para localizar sua configuração via informer com label selector. Como o Helm sobrescreve (não soma) valores de label na mesma chave, o valor virou `minitube`, e esses dois componentes entravam em `CrashLoopBackOff` permanente com `configmap "argocd-cm" not found" — mesmo com o ConfigMap existindo, com o nome certo, no namespace certo, com RBAC correto (confirmado metodicamente via `kubectl auth can-i` antes de suspeitar do label). `redis`, `repo-server` e `applicationset-controller` seguiam saudáveis, o que ajudou a isolar a causa aos dois componentes que dependem desse informer. Corrigido removendo `global.additionalLabels` — o agrupamento "part-of: minitube" já existe no Namespace, sem colisão.
5. **`targetRevision` fixo em `main` impedindo validar a própria branch.** A Application `platform` apontava para `targetRevision: main`, mas `gitops/platform/` só existia na branch `feat/argocd-bootstrap` (ainda não mergeada) — `path does not exist`. Corrigido parametrizando a revision (`var.argocd_gitops_revision`, default `main`), permitindo validar a branch atual via `-var` sem hardcode nem necessidade de merge prematuro só para testar.
6. **Ordem de destroy revogando o próprio acesso no meio do processo.** No `terraform destroy` final, o `aws_eks_access_entry.operator`/`aws_eks_access_policy_association.operator_admin` foram removidos antes do namespace/secret do ArgoCD (nenhuma dependência explícita entre eles), derrubando o acesso `kubectl` do operador a meio caminho — o erro reportado (`cannot delete resource "secrets"`) era na real "sua identidade não tem mais nenhum binding neste cluster". Corrigido com `depends_on` explícito em `kubernetes_namespace_v1.argocd`, garantindo a ordem inversa correta no destroy. Recuperado nesta sessão via `terraform state rm` dos dois recursos Kubernetes órfãos (o cluster inteiro seria destruído a seguir de qualquer forma) + `terraform destroy` normal para o restante.

## Como validamos

[`docs/runbooks/validate-argocd-gitops.md`](../runbooks/validate-argocd-gitops.md) + `terraform/envs/lab/scripts/validate-argocd.sh`: confirma os componentes do ArgoCD `Available`, as duas Applications raiz `Synced`/`Healthy`, que `Deployment/api` carrega a annotation de tracking do ArgoCD (prova de que não veio de `kubectl apply` manual), que a API responde via port-forward, e — a checagem central — que um drift manual (`kubectl scale --replicas=2`) é revertido pelo `selfHeal` sozinho, sem qualquer intervenção. Todas as checagens passaram, com o drift revertido em ~5s. Também rodamos `validate-transcoding.sh` de novo, confirmando que a app agora 100% sincronizada via GitOps ainda transcodifica um vídeo real de ponta a ponta.

## Lições aprendidas

- **Labels globais de Helm chart podem colidir com labels que o próprio chart usa internamente.** `global.additionalLabels`/valores equivalentes sobrescrevem, não somam — sempre checar se a chave escolhida já é usada pelo chart antes de aplicá-la globalmente, especialmente em charts complexos como o `argo-cd` que usam label selectors em runtime, não só para organização visual.
- **`terraform import` resolve “drift externo” sem sair do fluxo IaC.** Tanto o access entry auto-criado pela AWS quanto (num momento de troubleshooting) um Helm release órfão de um `apply` interrompido foram recuperados via `terraform import`, evitando qualquer comando `aws`/`helm` manual fora do Terraform — mantém o princípio "tudo é código" mesmo ao lidar com efeitos colaterais da própria AWS/Helm.
- **Testar uma Application do ArgoCD antes do merge exige apontar para a branch.** Um `targetRevision` fixo em `main` é o certo para produção, mas fixa uma dependência circular ao validar infraestrutura nova numa branch — parametrizar essa revision (default seguro, override pontual) resolve sem abrir mão da validação funcional real antes do merge.

## Estado final da fase

- Critério de conclusão cumprido: nenhum `kubectl apply` manual — `gitops/app/` e `gitops/platform/` são reconciliados pelo ArgoCD a partir do Git, confirmado por teste funcional real (incluindo prova de self-heal).
- `terraform/bootstrap-iam/` ganhou 2 novas concessões de IAM (persistentes, sem custo); `terraform/envs/lab/` (VPC, EKS, S3, IRSA, ArgoCD) confirmado destruído ao final da sessão.
- Visibilidade do repositório: brevemente tornado público nesta sessão (conveniência de `git pull` no CloudShell) e revertido para **privado** ainda na mesma sessão — o projeto fica privado durante todo o desenvolvimento e vira público deliberadamente ao final, para divulgação em portfólio/LinkedIn. Ver ADR 007.
- PR desta fase: branch `feat/argocd-bootstrap` *(atualizar o link do PR quando aberto)*.

## Próxima fase

[Fase 4 — Borda, DNS e TLS](../../CLAUDE.md#fases-do-projeto): CloudFront na frente do S3; Route 53 + external-dns + cert-manager com o domínio próprio do operador — critério de conclusão: `app.<domínio>` servindo vídeo via CDN com HTTPS válido, mais um ADR sobre a persistência da zona DNS entre sessões.
