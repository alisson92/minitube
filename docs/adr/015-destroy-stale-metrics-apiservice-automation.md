# 015 — Automação da limpeza da APIService órfã do metrics-server no destroy

## Status

Aceito

## Contexto

Repetição do sintoma já documentado em [`docs/runbooks/run-the-project.md`](../runbooks/run-the-project.md)
(seção "Se o `destroy` travar em `kubernetes_namespace_v1.argocd`/`.platform`"):
`terraform destroy` de `envs/lab` travou em `kubernetes_namespace_v1.argocd`
e `kubernetes_namespace_v1.platform` por 5+ minutos, terminando em
`Error: context deadline exceeded`, logo depois do `helm uninstall` de
`argocd-apps` (que podou a Application `metrics-server`).

Causa raiz (já diagnosticada na sessão que gerou o runbook, agora corrigida
em código): destruir `helm_release.argocd_apps` remove a Application
`metrics-server` do ArgoCD, que por sua vez desinstala o chart -- mas o
`APIService` `v1beta1.metrics.k8s.io` (registro de API cluster-scoped, criado
pelo chart, não gerenciado por Terraform nem pelo ArgoCD diretamente)
sobrevive, apontando para um backend que não existe mais. Enquanto essa
`APIService` quebrada existir, a descoberta de API do cluster inteiro falha
(`DiscoveryFailed: metrics.k8s.io/v1beta1: stale GroupVersion discovery`), e
o controller de finalização de namespace do Kubernetes -- que depende dessa
descoberta completa -- trava para **qualquer** namespace em terminação, não
só o do metrics-server. Isso bloqueia os dois namespaces geridos diretamente
pelo Terraform (`kubernetes_namespace_v1.argocd`/`.platform`, necessários
desde a decisão 12 do [ADR 011](011-observability-stack.md) para
`kubernetes_secret_v1.grafana_admin`).

Até esta sessão, a correção era só documentada como playbook manual: rodar
`kubectl delete apiservice v1beta1.metrics.k8s.io`, depois reexecutar
`terraform destroy`. Funcional, mas viola o objetivo de `destroy` correr do
início ao fim numa única execução sem intervenção humana (mesmo objetivo já
perseguido pelo [ADR 010](010-lbc-orphan-cleanup-and-alb-wait.md) para o
`apply`).

## Decisões

### 1. `null_resource` com `provisioner "local-exec" { when = destroy }`

Adicionado `null_resource.cleanup_stale_metrics_apiservice`
(`terraform/envs/lab/argocd.tf`), cujo destroy-time provisioner roda
`aws eks update-kubeconfig` (gerando um kubeconfig efêmero em `mktemp`,
nunca tocando `~/.kube/config` -- importante porque o contexto padrão da
máquina do operador aponta para um cluster Kind local, não para o EKS deste
projeto) seguido de `kubectl delete apiservice v1beta1.metrics.k8s.io
--ignore-not-found`.

**Por que AWS CLI + kubectl via `local-exec`, não o provider `kubernetes`:**
destroy-time provisioners só podem referenciar atributos do próprio recurso
(`self`) -- não podem referenciar outros recursos/data sources diretamente,
porque não há garantia do estado deles nesse ponto do destroy. Por isso
`cluster_name` e `aws_region` são passados via `triggers` do próprio
`null_resource` e lidos como `self.triggers.*` dentro do script, em vez de
interpolar `module.eks.cluster_name`/`var.aws_region` direto no comando (o
que o Terraform rejeitaria: "Invalid reference from destroy provisioner").
Um `data "kubernetes_..."` também não serviria -- o provider `kubernetes` não
expõe um jeito declarativo de deletar um recurso que ele próprio nunca criou.

### 2. Ordenação: depois de `argocd_apps`, antes dos namespaces

`helm_release.argocd_apps` ganhou `null_resource.cleanup_stale_metrics_apiservice`
no seu `depends_on`, e o próprio `null_resource` tem
`depends_on = [kubernetes_namespace_v1.argocd, kubernetes_namespace_v1.platform]`.
Como `destroy` inverte a ordem de dependência (quem depende é destruído
primeiro), isso força a sequência: `argocd_apps` destruído primeiro (a
Application `metrics-server` é podada, a `APIService` fica órfã) → o
`null_resource` destruído em seguida (roda a limpeza, exatamente quando a
`APIService` já está órfã mas antes de qualquer namespace tentar finalizar)
→ os dois namespaces destruídos por último, agora sem a descoberta de API
quebrada no caminho.

**Alternativa descartada:** adicionar a limpeza como um provisioner de
destroy diretamente nos próprios `kubernetes_namespace_v1.argocd`/`.platform`.
Rejeitada porque um `null_resource` dedicado deixa a ordenação explícita e
reaproveitável (um único recurso cobre os dois namespaces), em vez de
duplicar o mesmo script em dois lugares com a mesma condição de corrida
entre eles.

### 3. `docs/runbooks/run-the-project.md` atualizado, não removido

A seção do playbook manual foi mantida, mas reescrita para apontar que a
limpeza agora é automática (referenciando este ADR) -- útil como diagnóstico
de fallback caso o próprio `null_resource` falhe por algum motivo (ex.:
`aws`/`kubectl` ausentes do `PATH`, ou uma causa raiz diferente da
já conhecida).

## Consequências

- `terraform/envs/lab/argocd.tf`: novo `resource "null_resource"
  "cleanup_stale_metrics_apiservice"`; `helm_release.argocd_apps` ganha essa
  dependência adicional.
- `docs/runbooks/run-the-project.md`: seção do playbook manual atualizada
  para refletir a automação, mantida como fallback documentado.
- **Não cobre retroativamente um `destroy` já em andamento/travado no exato
  momento em que este fix foi escrito** -- o `null_resource` só entra em
  ação a partir do momento em que existir no state (ou seja, depois de um
  `apply` que o crie, ainda que como no-op). Para destravar uma execução já
  parada nos namespaces com `helm_release.argocd_apps` já destruído (fora do
  state), a opção mais direta é `terraform apply -target=null_resource.cleanup_stale_metrics_apiservice`
  seguido de `terraform destroy` normal -- não o playbook manual antigo.
  Só a partir do próximo ciclo `apply`→`destroy` completo do zero é que a
  automação cobre o cenário de ponta a ponta sem esse passo extra.
- Validação funcional real (a automação realmente elimina o
  `context deadline exceeded`) ainda não executada nesta sessão -- a
  registrar como atualização futura quando um ciclo completo confirmar.
