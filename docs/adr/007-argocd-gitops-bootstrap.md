# 007 — Bootstrap do ArgoCD e sincronização GitOps

## Status

Aceito

## Contexto

Critério de conclusão da Fase 3 (`CLAUDE.md`): "Nenhum `kubectl apply` manual — todo deploy sai do Git". O ADR 006 (item 7) já registrava essa lacuna como exceção temporária: `gitops/app/` era aplicado manualmente via `kubectl apply -k`, com a promessa explícita de que "nenhum `kubectl apply` continuará manual além da Fase 3". Esta fase instala o ArgoCD e faz ele assumir a reconciliação completa de `gitops/app/`, além de preparar `gitops/platform/` (inexistente até aqui) para os componentes de observabilidade da Fase 5.

O repositório GitHub (`alisson92/minitube`) é **privado** — o ArgoCD, rodando dentro do cluster, precisa de credencial própria para clonar o Git; não herda a chave SSH local do operador.

## Decisões

### 1. Instalação do ArgoCD via `helm_release` do Terraform, não `helm install` manual

O chart oficial `argo-cd` (repositório `argo-helm`) é instalado como um `helm_release` em `terraform/envs/lab/argocd.tf`, com os providers `kubernetes`/`helm` autenticados a partir dos próprios atributos do `aws_eks_cluster.lab` (via `data "aws_eks_cluster_auth"`) — sem escrever kubeconfig em disco. Como a infraestrutura de `envs/lab` é destruída e recriada em toda sessão (princípio de efemeridade do projeto), qualquer passo imperativo (`helm install`) precisaria ser lembrado e reexecutado manualmente a cada sessão — o mesmo tipo de fricção operacional já descartado em decisões anteriores (ADR 002). Um único `terraform apply` passa a recriar VPC, EKS, S3, IRSA **e** o ArgoCD.

### 2. Bootstrap das Applications raiz via chart `argocd-apps`, não uma Application YAML aplicada manualmente

O chart `argocd-apps` (mesmo repositório `argo-helm`) permite declarar `Application`/`AppProject`/`ApplicationSet` via values do Helm. Usado como um segundo `helm_release` para criar duas Applications raiz — `app` (aponta para `gitops/app`, destino `minitube-app`) e `platform` (aponta para `gitops/platform`, destino `minitube-platform`) — e o `AppProject minitube-platform`. Isso fecha o próprio ato de "dar o primeiro `kubectl apply` para o ArgoCD existir": mesmo a criação das Applications continua 100% declarativa e reprodutível via `terraform apply`, em vez de reabrir a exceção que esta fase deveria encerrar.

### 3. `gitops/platform/` criado agora só com `README.md`; `AppProject` declarado via Terraform, não dentro do diretório Git

O diretório é criado nesta fase (com a Application `platform` já apontando para ele) mesmo sem conteúdo real ainda — a Fase 5 (kube-prometheus-stack/Loki) só vai precisar adicionar manifests a um Git path que já existe e já está sendo sincronizado, sem tocar Terraform de novo. O `AppProject minitube-platform` fica declarado via Terraform (chart `argocd-apps`), não como um manifest dentro de `gitops/platform/`: colocá-lo ali criaria um problema de ovo-e-galinha — a própria Application que sincroniza esse diretório precisa referenciar um `project` que, se vivesse só no Git, ainda não existiria no primeiro sync.

### 4. Deploy key SSH somente-leitura dedicada

Avaliado com o operador do projeto: deploy key SSH read-only (escolhida) vs. Personal Access Token vs. tornar o repositório público. A deploy key foi escolhida por ter o escopo mais estreito possível — read-only, restrita a este único repositório, sem tocar em nenhum outro recurso da conta GitHub do operador. A chave pública é cadastrada no GitHub via `gh repo deploy-key add`; a privada é passada só via `TF_VAR_argocd_repo_ssh_private_key` (variável `sensitive = true`, sem default) e vira um `kubernetes_secret_v1` no formato de repository credential que o ArgoCD espera (label `argocd.argoproj.io/secret-type: repository`) — nunca commitada, mesmo padrão de segredos via variável de ambiente local já usado no projeto (`docs/engineering-standards.md` §8).

> **Atualização (Fase 4, ADR 008):** essa forma de passar a chave (`TF_VAR` sem persistência) exigia gerar um novo par e recadastrar a deploy key a cada sessão que recriasse `envs/lab` — atrito real, descoberto na prática, contrário ao princípio de que recriar o ambiente do zero deve ser indolor. A partir da Fase 4, a chave privada persiste em `aws_ssm_parameter` (`terraform/bootstrap/ssm.tf`), lida via `data source` em vez de `TF_VAR` a cada apply. A escolha da deploy key em si (vs. PAT/repositório público) continua válida — só o mecanismo de persistência do valor mudou. Ver [ADR 008](008-cloudfront-dns-tls.md), decisão 10.

### 5. Dex e o notifications-controller desabilitados

`dex.enabled=false` e `notifications.enabled=false` nos values do chart `argo-cd` (`terraform/envs/lab/values/argocd.yaml`). Não há SSO nem canal de notificação (Slack/e-mail/webhook) configurado ainda — manter esses componentes ativos seria custo de recursos (CPU/memória no node group pequeno, já hospedando API+transcoder) sem uso real. YAGNI, revisitável quando o projeto de fato precisar de um desses.

### 6. Acesso à UI do ArgoCD só via `kubectl port-forward` nesta fase

Sem Ingress/DNS/TLS ainda — isso é entregável da Fase 4 (`app.<domínio>`, `argocd.<domínio>` via Route 53 + external-dns + cert-manager). `server.service.type` permanece `ClusterIP` (já é o default do chart).

### 7. Self-management do ArgoCD (padrão app-in-app) adiado

Avaliado e descartado por ora. A infraestrutura de `envs/lab` é destruída e recriada toda sessão — logo o ArgoCD sempre vai precisar de um bootstrap externo ao Git no início de cada sessão (o próprio `helm_release.argocd`), independentemente de ele passar a se auto-gerenciar depois disso. Implementar self-management agora duplicaria a definição do chart `argo-cd` em dois lugares (o `helm_release` inicial do Terraform e uma futura Application que assumiria o gerenciamento) — dois pontos de verdade para os mesmos values, risco real de drift entre eles, sem ganho prático neste estágio: não há hoje múltiplos operadores mudando a configuração do próprio ArgoCD, nem necessidade de auditar essas mudanças via PR. Fica registrado como candidato futuro em `gitops/platform/README.md`, a reconsiderar apenas se o ArgoCD passar a ser infraestrutura persistente entre sessões (o que contradiria o princípio de efemeridade já validado) ou se o projeto ganhar múltiplos operadores.

### 8. Ordem de execução no `terraform apply`

Os providers `kubernetes`/`helm` referenciam atributos do `aws_eks_cluster.lab` do mesmo state (`endpoint`, `certificate_authority[0].data`) — não um module/state separado — então um único `terraform apply` funciona no caso comum, com o Terraform ordenando cluster → node group → recursos `kubernetes`/`helm` automaticamente pela dependência implícita. Ressalva conhecida da comunidade Terraform+EKS+Helm: na primeira vez que um cluster **totalmente novo** nasce na mesma run em que um `helm_release` também é aplicado, o provider `helm`/`kubernetes` pode falhar por conexão (`connection refused`/timeout) se tentar autenticar antes do control plane estar plenamente pronto para servir requisições. Como este projeto recria o cluster do zero em toda sessão, esse é o cenário mais comum, não a exceção — documentado no runbook um fallback com `-target` em duas etapas (cluster+node group+OIDC provider primeiro, resto depois), em vez de tentar "resolver" isso no HCL.

**Bug real, descoberto no `destroy`:** o inverso da ordem de criação também importa e não é automático. `kubernetes_namespace_v1.argocd` não referenciava `aws_eks_access_entry.operator`/`aws_eks_access_policy_association.operator_admin` de nenhuma forma, então o Terraform não tinha como saber que o destroy desses dois precisa acontecer **depois** dos recursos Kubernetes — num `destroy` real, o access entry foi removido antes do namespace/secret do ArgoCD, revogando o acesso `kubectl` do operador no meio do processo (`cannot delete resource "secrets"`, um erro de RBAC que na real é "sua identidade não tem mais nenhum binding neste cluster"). Corrigido com um `depends_on` explícito em `kubernetes_namespace_v1.argocd` apontando para os dois recursos de acesso — isso ordena a criação (contexto de acesso primeiro, inofensivo) e, mais importante, força a destruição dos recursos Kubernetes antes da revogação do acesso. Recuperação desta sessão específica: `terraform state rm` nos dois recursos Kubernetes órfãos (o cluster inteiro seria destruído a seguir de qualquer forma, então não fazia sentido perseguir acesso `kubectl` só para apagá-los individualmente) seguido de `terraform destroy` normal para o restante.

### 9. Bug real: `global.additionalLabels` sobrescrevendo o `part-of` interno do ArgoCD

Descoberto em teste real, não previsto no desenho original: a primeira versão de `values/argocd.yaml` incluía `global.additionalLabels: {app.kubernetes.io/part-of: minitube}`, pensada só como rótulo de agrupamento. O chart `argo-cd` já define `app.kubernetes.io/part-of: argocd` em todos os seus recursos (incluindo `argocd-cm`/`argocd-secret`) — e o próprio `argocd-server`/`argocd-application-controller` usa um informer com esse label selector para localizar sua própria configuração em tempo de execução. Como `additionalLabels` **sobrescreve** (mesma chave), não adiciona, o valor virou `minitube`, e os dois componentes que dependem desse filtro entravam em `CrashLoopBackOff` permanente com `configmap "argocd-cm" not found` — mesmo com o ConfigMap existindo, visível e com RBAC correto (confirmado via `kubectl auth can-i`). `redis`, `repo-server` e `applicationset-controller` seguiam saudáveis por não dependerem desse filtro, o que ajudou a isolar a causa.

Corrigido removendo `global.additionalLabels` de `values/argocd.yaml` — o agrupamento "part-of: minitube" já existe no nível do Namespace (`kubernetes_namespace_v1.argocd`), que não colide com nada interno ao chart. Lição registrada como comentário no próprio arquivo de values.

### 10. Concessões de IAM adicionais descobertas em teste real (CreateNodegroup)

Duas lacunas na mesma classe das já documentadas no ADR 006 (verificações do provider/API não óbvias a partir do recurso declarado): `CreateNodegroup` (chamado pelo `aws_eks_node_group.lab_spot`) valida as managed policies já anexadas à role do node (`iam:ListAttachedRolePolicies`) e confirma que o service-linked role `AWSServiceRoleForAmazonEKSNodegroup` já existe via `iam:GetRole` direto nesse ARN — nenhuma das duas coberta pela `Statement` `PassEksRoles` original (só tinha `GetRole`/`PassRole` nas roles do cluster/node, não no SLR). Ambas só apareceram porque, nesta sessão, foi o `cloudlab-operator` (não CloudShell/root) quem chamou `CreateNodegroup` pela primeira vez. Corrigidas com uma action adicional na própria `Statement` `PassEksRoles` e uma nova `Statement` `ReadEksServiceLinkedRoles` (somente `iam:GetRole`, escopada aos dois SLRs do EKS), ambas em `terraform/bootstrap-iam/main.tf`.

### 11. Conflito com o access entry auto-criado pelo `bootstrap_cluster_creator_admin_permissions`

Também descoberto em teste real: como o `cloudlab-operator` passou a ser quem cria o cluster nesta sessão (ao contrário das Fases 1–2, em que era o CloudShell/root), o `bootstrap_cluster_creator_admin_permissions = true` (ADR 004) já cria automaticamente, do lado da AWS, um access entry + associação `AmazonEKSClusterAdminPolicy` para esse mesmo principal — entrando em conflito (`ResourceInUseException`) com o `aws_eks_access_entry.operator` explícito que o Terraform tenta criar por cima. Resolvido nesta sessão via `terraform import` do access entry já existente para dentro do state (sem recorrer a nenhum comando `aws eks` manual fora do Terraform) — não uma mudança de código, já que o próprio `bootstrap_cluster_creator_admin_permissions` não é retroativamente alterável num cluster já criado. Fica registrado aqui para a próxima sessão: se o mesmo principal criar o cluster de novo, o comportamento se repete, e o mesmo `terraform import` resolve.

### Alternativas consideradas

- **`helm install` manual:** descartada — reintroduz um passo imperativo que precisaria ser lembrado e reexecutado a cada sessão, quebrando o princípio de infraestrutura efêmera "indolor de recriar".
- **Argo CD Autopilot:** descartada — ferramenta de bootstrap própria, foge do padrão Terraform-first já estabelecido nas fases anteriores; não traz benefício didático adicional para este projeto.
- **`Application` YAML aplicada manualmente uma vez:** descartada — reabriria, mesmo que só uma vez, a exceção de `kubectl apply` manual que a Fase 3 existe para encerrar.
- **`AppProject` dentro de `gitops/platform/`:** descartada — problema de ovo-e-galinha (ver decisão 3).
- **PAT (Personal Access Token):** descartada — escopo tipicamente mais amplo que uma deploy key, sujeito a expiração, gerenciado à parte da configuração do repositório.
- **Tornar o repositório público:** descartada nesta decisão — eliminaria a necessidade de credencial, mas exporia publicamente ADRs com detalhes de conta AWS e todo o histórico do projeto. **Atualização, ainda na mesma sessão:** o repositório foi tornado público pelo operador por conveniência operacional (permitir `git pull` direto no CloudShell sem configurar credencial Git lá), depois da deploy key já estar implementada, e revertido para privado ainda na mesma sessão, com a intenção do projeto esclarecida: o repositório se torna público **deliberadamente ao final do projeto** (divulgação em portfólio/LinkedIn), não incidentalmente durante o desenvolvimento. A deploy key SSH segue funcionando normalmente em ambos os casos (não depende da visibilidade do repositório).
- **Self-management do ArgoCD (app-in-app) já nesta fase:** descartada — ver decisão 7.

## Consequências

- `terraform/envs/lab/versions.tf` ganha os providers `kubernetes` (`~> 3.2`) e `helm` (`~> 3.2`).
- `terraform/envs/lab/main.tf` ganha `data "aws_eks_cluster_auth" "lab"` e os providers `kubernetes`/`helm` configurados a partir dos atributos do cluster.
- `terraform/envs/lab/variables.tf` ganha `argocd_repo_ssh_private_key` (sensível, sem default), `argocd_chart_version`, `argocd_apps_chart_version`, `argocd_gitops_revision` (default `main` — parametrizado para permitir validar uma branch antes do merge, ver decisão 3 e retrospecto da fase).
- `terraform/envs/lab/values/argocd.yaml` (novo) define os values do chart `argo-cd` — Dex/notifications desabilitados, `resources.requests/limits` explícitos em todos os componentes ativos (o chart não define limites por default).
- `terraform/envs/lab/argocd.tf` (novo) cria o namespace `argocd`, o `kubernetes_secret_v1` de credencial de repositório, e os dois `helm_release` (`argo-cd`, `argocd-apps`).
- `terraform/envs/lab/outputs.tf` ganha `argocd_namespace`.
- `gitops/app/kustomization.yaml` deixa de instruir aplicação manual; `gitops/app/namespace.yaml` e `gitops/app/deployment.yaml` trocam o label `app.kubernetes.io/managed-by` de `kubectl` para `argocd`.
- `gitops/platform/README.md` (novo) — primeiro arquivo do diretório, documentando seu propósito e o que chega na Fase 5.
- A validação funcional pós-apply ganha `terraform/envs/lab/scripts/validate-argocd.sh` e o runbook [`docs/runbooks/validate/validate-argocd-gitops.md`](../runbooks/validate/validate-argocd-gitops.md) — a checagem central prova que um drift manual é revertido pelo `selfHeal` sem qualquer `kubectl apply`.
- `docs/runbooks/validate/validate-transcoding.md` e o cabeçalho de `terraform/envs/lab/scripts/validate-transcoding.sh` deixam de mencionar `kubectl apply -k` como pré-requisito.
- `kubectl apply -k gitops/app/` deixa de ser necessário em qualquer fluxo documentado do projeto a partir desta fase — a exceção temporária aberta no ADR 006 (item 7) está encerrada.
- `terraform/bootstrap-iam/main.tf` ganha uma action (`iam:ListAttachedRolePolicies`) na `Statement` `PassEksRoles` existente e uma `Statement` nova (`ReadEksServiceLinkedRoles`) — ver decisão 10.
