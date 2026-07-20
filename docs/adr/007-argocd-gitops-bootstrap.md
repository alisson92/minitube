# 007 — Bootstrap do ArgoCD e sincronização GitOps

## Status

Aceito

## Contexto

Critério de conclusão da Fase 3 (`CLAUDE.md`): "Nenhum `kubectl apply` manual — todo deploy sai do Git". O ADR 006 (item 7) já registrava essa lacuna como exceção temporária: `gitops/app/` era aplicado manualmente via `kubectl apply -k`, com a promessa explícita de que "nenhum `kubectl apply` continuará manual além da Fase 3". Esta fase instala o ArgoCD e faz ele assumir a reconciliação completa de `gitops/app/`, além de preparar `gitops/plataforma/` (inexistente até aqui) para os componentes de observabilidade da Fase 5.

O repositório GitHub (`alisson92/minitube`) é **privado** — o ArgoCD, rodando dentro do cluster, precisa de credencial própria para clonar o Git; não herda a chave SSH local do operador.

## Decisões

### 1. Instalação do ArgoCD via `helm_release` do Terraform, não `helm install` manual

O chart oficial `argo-cd` (repositório `argo-helm`) é instalado como um `helm_release` em `terraform/envs/lab/argocd.tf`, com os providers `kubernetes`/`helm` autenticados a partir dos próprios atributos do `aws_eks_cluster.lab` (via `data "aws_eks_cluster_auth"`) — sem escrever kubeconfig em disco. Como a infraestrutura de `envs/lab` é destruída e recriada em toda sessão (princípio de efemeridade do projeto), qualquer passo imperativo (`helm install`) precisaria ser lembrado e reexecutado manualmente a cada sessão — o mesmo tipo de fricção operacional já descartado em decisões anteriores (ADR 002). Um único `terraform apply` passa a recriar VPC, EKS, S3, IRSA **e** o ArgoCD.

### 2. Bootstrap das Applications raiz via chart `argocd-apps`, não uma Application YAML aplicada manualmente

O chart `argocd-apps` (mesmo repositório `argo-helm`) permite declarar `Application`/`AppProject`/`ApplicationSet` via values do Helm. Usado como um segundo `helm_release` para criar duas Applications raiz — `app` (aponta para `gitops/app`, destino `minitube-app`) e `platform` (aponta para `gitops/plataforma`, destino `minitube-platform`) — e o `AppProject minitube-platform`. Isso fecha o próprio ato de "dar o primeiro `kubectl apply` para o ArgoCD existir": mesmo a criação das Applications continua 100% declarativa e reprodutível via `terraform apply`, em vez de reabrir a exceção que esta fase deveria encerrar.

### 3. `gitops/plataforma/` criado agora só com `README.md`; `AppProject` declarado via Terraform, não dentro do diretório Git

O diretório é criado nesta fase (com a Application `platform` já apontando para ele) mesmo sem conteúdo real ainda — a Fase 5 (kube-prometheus-stack/Loki) só vai precisar adicionar manifests a um Git path que já existe e já está sendo sincronizado, sem tocar Terraform de novo. O `AppProject minitube-platform` fica declarado via Terraform (chart `argocd-apps`), não como um manifest dentro de `gitops/plataforma/`: colocá-lo ali criaria um problema de ovo-e-galinha — a própria Application que sincroniza esse diretório precisa referenciar um `project` que, se vivesse só no Git, ainda não existiria no primeiro sync.

### 4. Deploy key SSH somente-leitura dedicada

Avaliado com o operador do projeto: deploy key SSH read-only (escolhida) vs. Personal Access Token vs. tornar o repositório público. A deploy key foi escolhida por ter o escopo mais estreito possível — read-only, restrita a este único repositório, sem tocar em nenhum outro recurso da conta GitHub do operador. A chave pública é cadastrada no GitHub via `gh repo deploy-key add`; a privada é passada só via `TF_VAR_argocd_repo_ssh_private_key` (variável `sensitive = true`, sem default) e vira um `kubernetes_secret_v1` no formato de repository credential que o ArgoCD espera (label `argocd.argoproj.io/secret-type: repository`) — nunca commitada, mesmo padrão de segredos via variável de ambiente local já usado no projeto (`docs/engineering-standards.md` §8).

### 5. Dex e o notifications-controller desabilitados

`dex.enabled=false` e `notifications.enabled=false` nos values do chart `argo-cd` (`terraform/envs/lab/values/argocd.yaml`). Não há SSO nem canal de notificação (Slack/e-mail/webhook) configurado ainda — manter esses componentes ativos seria custo de recursos (CPU/memória no node group pequeno, já hospedando API+transcoder) sem uso real. YAGNI, revisitável quando o projeto de fato precisar de um desses.

### 6. Acesso à UI do ArgoCD só via `kubectl port-forward` nesta fase

Sem Ingress/DNS/TLS ainda — isso é entregável da Fase 4 (`app.<domínio>`, `argocd.<domínio>` via Route 53 + external-dns + cert-manager). `server.service.type` permanece `ClusterIP` (já é o default do chart).

### 7. Self-management do ArgoCD (padrão app-in-app) adiado

Avaliado e descartado por ora. A infraestrutura de `envs/lab` é destruída e recriada toda sessão — logo o ArgoCD sempre vai precisar de um bootstrap externo ao Git no início de cada sessão (o próprio `helm_release.argocd`), independentemente de ele passar a se auto-gerenciar depois disso. Implementar self-management agora duplicaria a definição do chart `argo-cd` em dois lugares (o `helm_release` inicial do Terraform e uma futura Application que assumiria o gerenciamento) — dois pontos de verdade para os mesmos values, risco real de drift entre eles, sem ganho prático neste estágio: não há hoje múltiplos operadores mudando a configuração do próprio ArgoCD, nem necessidade de auditar essas mudanças via PR. Fica registrado como candidato futuro em `gitops/plataforma/README.md`, a reconsiderar apenas se o ArgoCD passar a ser infraestrutura persistente entre sessões (o que contradiria o princípio de efemeridade já validado) ou se o projeto ganhar múltiplos operadores.

### 8. Ordem de execução no `terraform apply`

Os providers `kubernetes`/`helm` referenciam atributos do `aws_eks_cluster.lab` do mesmo state (`endpoint`, `certificate_authority[0].data`) — não um module/state separado — então um único `terraform apply` funciona no caso comum, com o Terraform ordenando cluster → node group → recursos `kubernetes`/`helm` automaticamente pela dependência implícita. Ressalva conhecida da comunidade Terraform+EKS+Helm: na primeira vez que um cluster **totalmente novo** nasce na mesma run em que um `helm_release` também é aplicado, o provider `helm`/`kubernetes` pode falhar por conexão (`connection refused`/timeout) se tentar autenticar antes do control plane estar plenamente pronto para servir requisições. Como este projeto recria o cluster do zero em toda sessão, esse é o cenário mais comum, não a exceção — documentado no runbook um fallback com `-target` em duas etapas (cluster+node group+OIDC provider primeiro, resto depois), em vez de tentar "resolver" isso no HCL.

### Alternativas consideradas

- **`helm install` manual:** descartada — reintroduz um passo imperativo que precisaria ser lembrado e reexecutado a cada sessão, quebrando o princípio de infraestrutura efêmera "indolor de recriar".
- **Argo CD Autopilot:** descartada — ferramenta de bootstrap própria, foge do padrão Terraform-first já estabelecido nas fases anteriores; não traz benefício didático adicional para este projeto.
- **`Application` YAML aplicada manualmente uma vez:** descartada — reabriria, mesmo que só uma vez, a exceção de `kubectl apply` manual que a Fase 3 existe para encerrar.
- **`AppProject` dentro de `gitops/plataforma/`:** descartada — problema de ovo-e-galinha (ver decisão 3).
- **PAT (Personal Access Token):** descartada — escopo tipicamente mais amplo que uma deploy key, sujeito a expiração, gerenciado à parte da configuração do repositório.
- **Tornar o repositório público:** descartada — eliminaria a necessidade de credencial, mas exporia publicamente ADRs com detalhes de conta AWS e todo o histórico do projeto.
- **Self-management do ArgoCD (app-in-app) já nesta fase:** descartada — ver decisão 7.

## Consequências

- `terraform/envs/lab/versions.tf` ganha os providers `kubernetes` (`~> 3.2`) e `helm` (`~> 3.2`).
- `terraform/envs/lab/main.tf` ganha `data "aws_eks_cluster_auth" "lab"` e os providers `kubernetes`/`helm` configurados a partir dos atributos do cluster.
- `terraform/envs/lab/variables.tf` ganha `argocd_repo_ssh_private_key` (sensível, sem default), `argocd_chart_version`, `argocd_apps_chart_version`.
- `terraform/envs/lab/values/argocd.yaml` (novo) define os values do chart `argo-cd` — Dex/notifications desabilitados, `resources.requests/limits` explícitos em todos os componentes ativos (o chart não define limites por default).
- `terraform/envs/lab/argocd.tf` (novo) cria o namespace `argocd`, o `kubernetes_secret_v1` de credencial de repositório, e os dois `helm_release` (`argo-cd`, `argocd-apps`).
- `terraform/envs/lab/outputs.tf` ganha `argocd_namespace`.
- `gitops/app/kustomization.yaml` deixa de instruir aplicação manual; `gitops/app/namespace.yaml` e `gitops/app/deployment.yaml` trocam o label `app.kubernetes.io/managed-by` de `kubectl` para `argocd`.
- `gitops/plataforma/README.md` (novo) — primeiro arquivo do diretório, documentando seu propósito e o que chega na Fase 5.
- A validação funcional pós-apply ganha `terraform/envs/lab/scripts/validate-argocd.sh` e o runbook [`docs/runbooks/validate-argocd-gitops.md`](../runbooks/validate-argocd-gitops.md) — a checagem central prova que um drift manual é revertido pelo `selfHeal` sem qualquer `kubectl apply`.
- `docs/runbooks/validate-transcoding.md` e o cabeçalho de `terraform/envs/lab/scripts/validate-transcoding.sh` deixam de mencionar `kubectl apply -k` como pré-requisito.
- `kubectl apply -k gitops/app/` deixa de ser necessário em qualquer fluxo documentado do projeto a partir desta fase — a exceção temporária aberta no ADR 006 (item 7) está encerrada.
