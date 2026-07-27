# 011 — kube-prometheus-stack, Loki e EBS CSI driver via GitOps

## Status

Aceito

## Contexto

Fase 5 (Observabilidade) da tabela do `CLAUDE.md`: instalar `kube-prometheus-stack` e Loki via GitOps, com SLOs definidos antes dos testes de carga da Fase 6. O critério de conclusão documentado é explícito — "Dashboard 'dia do jogo' mostrando hit ratio do CDN, latência p95/p99, saturação e erros" — não um objetivo genérico de observabilidade, e isso molda várias das decisões abaixo (em especial 5 e 6).

Nenhum dos componentes desta fase existia antes: não havia EBS CSI driver, StorageClass, IRSA role de Grafana, nem instrumentação de métricas na API. Quatro decisões de escopo foram fechadas com o operador antes da implementação; as demais foram técnicas, descobertas ao verificar cada chart e cada arquivo real do repositório (não especulativas).

## Decisões

### 1. Node sizing: `min = max = desired = 3`, sem Cluster Autoscaler

O node group (`t3.medium` spot) estava em `desired=2, min=1, max=3`. O gargalo real para esta fase não é CPU/memória — sobra folga confortável mesmo com os 4 novos add-ons — é o limite de **17 pods/nó** do `t3.medium` via alocação de IP da VPC CNI (`(3 ENIs) × (6 IPs/ENI − 1) + 2 = 17`). Com os add-ons desta fase, o total de pods sobe apreciavelmente (ArgoCD + 3 add-ons da Fase 4 + kube-system + app + agora ebs-csi-driver + kube-prometheus-stack + Loki + promtail) — 2 nós (34 slots) não davam margem para rolling updates nem para o Job de transcodificação.

Corrigido subindo `eks_node_desired_size`/`eks_node_min_size`/`eks_node_max_size` para `3` (51 slots), mantendo o tipo de instância (`t3.medium` spot — barato, alinhado ao princípio de custo controlado do projeto).

**Por que `min = max = desired` em vez de só subir `desired`:** não existe Cluster Autoscaler nem Karpenter neste cluster. Sem um desses componentes observando pods `Pending` para decidir escalar, `min_size`/`max_size` diferentes de `desired_size` não têm efeito nenhum — são configuração morta, só limites de validação do node group. Fixar os três iguais deixa a intenção explícita: hoje é uma frota estática de 3 nós.

**Adiado deliberadamente para a Fase 6:** um autoscaler de cluster de verdade, dimensionado com dado real de carga do k6 (o próprio `CLAUDE.md` já prevê HPA/KEDA nessa fase) — decidir isso hoje, sem carga real, seria engenharia antecipada.

### 2. Loki: single-binary + filesystem via PVC, não distributed + S3

Evita um bucket S3 novo e uma IRSA role adicional para um ambiente que é destruído ao final de cada sessão — sem ganho prático de armazenamento durável. Exige um provisionador de volume dinâmico, que não existia neste cluster (decisão 3).

Dois charts oficiais separados (`grafana/loki` + `grafana/promtail`), não `loki-stack` (legado/depreciado upstream, sem version pinning granular por componente — quebraria o padrão já usado em todo `variables.tf`, onde cada componente tem sua própria `*_chart_version`).

**Gotcha real, só exposto em `helm template`:** `deploymentMode: SingleBinary` sozinho não zera os componentes do modo *SimpleScalable* (`write`/`read`/`backend`, replicas: 3 por padrão) — o chart falha o render (`templates/validate.yaml`) se ambos os modos tiverem réplicas > 0 simultaneamente. Corrigido zerando os três explicitamente. Também exigiu `loki.useTestSchema: true` (o chart documenta esse toggle como o atalho oficial "for testing or playing around" quando não há backend de objeto real — exatamente este caso) em vez de escrever um `schemaConfig` manual sem benefício prático aqui.

**Densidade de pods:** `lokiCanary`, `chunksCache` e `resultsCache` vêm habilitados por padrão (3 pods a mais — DaemonSet + 2 StatefulSets de memcached) — todos desabilitados, sem valor real no volume de consulta de um lab e mais 3 pods num node group já denso (decisão 1).

**Bug real, só exposto no primeiro deploy real (`helm template` não pega — é uma validação em runtime, não de render):** `loki-0` entrou em `CrashLoopBackOff` com `CONFIG ERROR: invalid compactor config: compactor.delete-request-store should be configured when retention is enabled`. O Loki 3.x passou a exigir um *delete request store* explícito quando `compactor.retention_enabled: true` está setado (decisão 2 já previa a retenção de 24h) — não basta habilitar a flag. Corrigido com `loki.compactor.delete_request_store: filesystem`, o mesmo backend já usado em `loki.storage.type`. Efeito em cascata: os 3 pods do `promtail` (DaemonSet) dependem do Service `loki` para enviar logs — com `loki-0` fora do ar, ficavam retentando `connection refused` indefinidamente; a falha de *readiness* reportada neles não era um bug próprio, era só a consequência visível deste.

### 3. EBS CSI driver via GitOps, não `aws_eks_addon`

Nenhum provisionador de volume dinâmico existia (confirmado: nenhum `aws_eks_addon`, nenhuma `StorageClass`, grep vazio por `ebs`/`csi`/`storageclass` em todo `terraform/envs/lab/`) — necessário para os PVCs de Prometheus e Loki.

Instalado como mais um subdiretório `gitops/platform/ebs-csi-driver/` + Application multi-source, o mesmo mecanismo já usado para `aws-load-balancer-controller`/`external-dns`/`cert-manager` na Fase 4, em vez de `aws_eks_addon` (a alternativa gerenciada pela AWS) — mantém um único padrão de instalação de add-on de plataforma no repositório, em vez de dois mecanismos concorrentes.

IRSA role com a policy **gerenciada** oficial da AWS (`AmazonEBSCSIDriverPolicy`, via `aws_iam_role_policy_attachment`), não uma policy inline própria — é o padrão documentado pela AWS para este driver especificamente, diferente dos outros 3 add-ons de plataforma (todos com policy inline). Isso exigiu um novo `Sid` (`AttachEbsCsiManagedPolicy`) na policy inline única do permission set do operador (`terraform/bootstrap-iam/main.tf`) — `ManagePlatformIrsaRoles` só cobria `iam:PutRolePolicy`/`DeleteRolePolicy` (ações de policy inline), não `iam:AttachRolePolicy`/`DetachRolePolicy`. Escopado por `iam:PolicyARN` a exatamente essa policy gerenciada, para que o grant não possa ser usado para anexar nada mais amplo a uma role `platform-*`.

Só o *controller* (que fala com a API da AWS) usa a IRSA role — o DaemonSet *node* só formata/monta localmente, sem chamadas AWS.

### 4. Risco conhecido, checado no destroy real: órfão de volume EBS

Mesma classe de bug já documentada 4 vezes para a ALB do LBC (ADR 008 itens 7-9 → ADR 009 decisões 5-6 → ADR 010): apagar uma `PVC` só dispara `DeleteVolume` de verdade se o pod controller do EBS CSI driver ainda estiver vivo e autorizado nesse instante. As Applications `kube-prometheus-stack` e `loki` (donas de PVC) ganharam o mesmo finalizer `resources-finalizer.argocd.argoproj.io` já usado por `app`/`platform`, e a policy do EBS CSI driver (junto com a do Grafana) entrou no `depends_on` de `helm_release.argocd_apps`, mesmo tratamento preventivo já dado à policy do LBC/external-dns no ADR 010. **Não há garantia de ordem entre Applications-irmãs dentro do mesmo `helm_release`** (o mesmo gap que o ADR 010 decisão 2 corrigiu para a `AppProject`) — o risco teórico era o pod do `ebs-csi-driver` ser removido antes da poda de PVC das outras duas terminar.

**Checado no primeiro `destroy` real desta fase: não se confirmou.** `aws ec2 describe-volumes` filtrado por `tag:kubernetes.io/created-for/pvc/name` não retornou nenhum volume — `destroy` limpo, sem órfãos. O `depends_on` preventivo (mitigação de baixo custo, sem downside) permanece no código; nenhuma correção adicional foi necessária.

### 5. Grafana precisa de IRSA própria, com acesso de leitura ao CloudWatch

Nenhum dos outros componentes desta fase faz chamadas à API da AWS — mas o critério de conclusão da Fase 5 exige hit ratio do CDN (CloudFront) e, na prática, erros da ALB (5xx), que são métricas `CloudWatch`, inexistentes no Prometheus. Sem essa role, o critério de conclusão da fase simplesmente não é cumprível.

Policy inline com o escopo mínimo documentado pelo plugin CloudWatch do Grafana (`GetMetricData`, `GetMetricStatistics`, `ListMetrics`, `DescribeAlarmsForMetric`, `tag:GetResources`), não a managed policy `CloudWatchReadOnlyAccess` (larga demais — inclui Logs/X-Ray/Synthetics), mantendo o padrão de menor privilégio já usado por cert-manager/external-dns neste arquivo. `Resource = "*"` porque essas ações somente-leitura de métricas não suportam scoping por ARN.

Nome do Service Account fixado explicitamente (`grafana`, via `grafana.serviceAccount.name` no `values.yaml`) em vez de depender do nome derivado do release — mesma razão de design já usada nos outros add-ons: a trust policy da IRSA role não pode depender de um nome que muda se a Application for renomeada no Terraform.

### 6. A API precisa expor `/metrics` — sem isso não há latência p95/p99 real

`app/api/main.py` só tinha `/api/healthz`, `/api/videos`, `/api/videos/{id}` (confirmado por leitura direta do arquivo antes de implementar) — nenhuma métrica de latência existia. Adicionada `prometheus-fastapi-instrumentator` (`app/api/requirements.txt`), instrumentando `/metrics` fora do prefixo `/api` de propósito: só é scrapeado internamente pelo `ServiceMonitor` via o Service `ClusterIP` (porta 8000), nunca passa pelo CloudFront/ALB (que só encaminham `/api/*`).

**Bug real de dependências, só exposto no build:** `prometheus-fastapi-instrumentator==8.0.2` (a versão mais recente na hora da implementação) exige `starlette>=1.0.0`, mas `fastapi==0.115.6` (já pinada no projeto) pina `starlette<0.42.0,>=0.40.0` — `ResolutionImpossible` no `pip install`. Corrigido fixando `prometheus-fastapi-instrumentator==7.1.0` (exige `starlette<1.0.0,>=0.30.0`, compatível). Validado localmente antes do push: build da imagem, execução do servidor real (fora do container Docker padrão, que falha ao importar `jobs.py` fora de um Pod real — comportamento pré-existente, não desta mudança) confirmando `/metrics` respondendo com o histograma `http_request_duration_seconds_bucket{handler,method,le}`. Imagem publicada como `v0.1.3` no ECR.

O Service `api` (`gitops/app/service.yaml`) ganhou uma porta nomeada (`http`) — `ServiceMonitor.spec.endpoints[].port` referencia porta por nome, não por número.

### 7. SLO mínimo viável, não elaborado

Disponibilidade via `kube_deployment_status_replicas_available{namespace="minitube-app", deployment="api"} < 1` — de graça via kube-state-metrics, sem depender da instrumentação da decisão 6. Latência via `histogram_quantile(0.95, ...)` sobre `http_request_duration_seconds_bucket`, com um limiar de 500ms **arbitrário** (ponto de partida para um lab, não um SLA validado) — revisar com dado real de carga na Fase 6. Nenhuma regra de saturação/erro elaborada nesta fase: CPU/memória de nó (node-exporter, já grátis) e erros 5xx (CloudWatch ALB, já coberto pela decisão 5) bastam para o critério de conclusão sem inventar SLOs sem dado real por trás.

### 8. Grafana exposto via Ingress, `grafana.<domínio>`

Já é uma URL-alvo documentada na arquitetura do projeto (`CLAUDE.md`). Mesmo padrão do `argocd.<domínio>` (ADR 008): TLS pelo certificado ACM wildcard persistente, mesma ALB compartilhada via `IngressGroup` (`group.name: minitube`), `group.order: "15"` — entre o ArgoCD (`10`, host-específico) e o catch-all da API (`20`) para não quebrar a prioridade de avaliação de regras já estabelecida.

### 9. Bug real: o webhook do Prometheus Operator via Job de Helm trava o sync no ArgoCD

A `Application kube-prometheus-stack` ficou presa em `OutOfSync` permanente, sem nenhum `Prometheus`/`Alertmanager` real chegando a ser criado pelo operator. `operationState.message` revelou a causa: `Resource batch/Job/kube-prometheus-stack-admission-create is missing, it might have been deleted. Retrying attempt #5`. Configuração padrão do chart (`prometheusOperator.admissionWebhooks.patch.enabled: true`, `deployment.enabled: false`) gera o certificado TLS do webhook de admissão via um par de Jobs de hook do Helm (`admission-create`/`admission-patch`, com `hook-delete-policy` própria) — o próprio `values.yaml` do chart já comenta a necessidade de anotá-los como hooks do ArgoCD (`argocd.argoproj.io/hook: PreSync`), mas isso não vem habilitado por padrão. Sem essa anotação, o ciclo de sync/prune do ArgoCD (mais o `retry` que este projeto já configura para esta Application, decisão análoga ao `cert-manager` da Fase 4) entra em corrida com o próprio ciclo de vida do Job, e o ArgoCD nunca considera o sync concluído.

Corrigido eliminando os Jobs por completo, não anotando-os: `prometheusOperator.admissionWebhooks.certManager.enabled: true` (o cert-manager, já rodando desde a Fase 4, passa a gerar o certificado via um `Issuer`/`Certificate` internos, self-signed, sem depender do `ClusterIssuer` externo do Let's Encrypt) + `patch.enabled: false` (desliga os Jobs) + `deployment.enabled: true` (o operator passa a servir o webhook nativamente via um segundo `Deployment` persistente, `kube-prometheus-stack-operator-webhook`, em vez do padrão TLS-via-patch-Job). Confirmado com `helm template`: zero `Job`s gerados, 2 `Certificate`/2 `Issuer` (self-signed) no lugar. Custo: +1 pod (o novo Deployment do webhook) — aceito, é o preço de eliminar uma classe inteira de race condition com o ArgoCD, mesmo racional de custo-benefício já usado nas decisões de bug real das fases anteriores.

### 10. Bug real: CRDs do Prometheus Operator grandes demais para client-side apply

Mesmo com a decisão 9 aplicada, a `Application kube-prometheus-stack` seguiu `OutOfSync` — desta vez por uma causa totalmente diferente, só visível olhando `status.resources[].status` recurso a recurso (o `operationState.message` de topo não é específico o bastante). As 6 CRDs do Prometheus Operator (`prometheuses`, `alertmanagers`, `alertmanagerconfigs`, `prometheusagents`, `scrapeconfigs`, `thanosrulers`) falhavam com `metadata.annotations: Too long: must have at most 262144 bytes`, com a própria mensagem de erro do Kubernetes já sugerindo a causa e a correção: *"This error usually means that you are trying to add a large resource on client side. Consider using Server-side apply"*. O *client-side apply* (o padrão do ArgoCD) grava o manifesto inteiro na annotation `kubectl.kubernetes.io/last-applied-configuration` — e essas CRDs específicas (schemas OpenAPI extensos do Prometheus Operator) já passam do limite de 256 KiB da API do Kubernetes para qualquer annotation. Sem as CRDs aplicadas, os recursos `Prometheus`/`Alertmanager` (que dependem delas) falhavam em cascata com `no matches for kind "Prometheus" in version "monitoring.coreos.com/v1"` — por isso nenhum pod real do Prometheus ou do Alertmanager chegou a ser criado pelo operator, mesmo com o operator e o webhook já `Running`.

Corrigido adicionando `"ServerSideApply=true"` a `syncOptions` da Application `kube-prometheus-stack` (`terraform/envs/lab/argocd.tf`) — troca o mecanismo de apply para o *Server-Side Apply* nativo do Kubernetes, que não depende dessa annotation. Nenhuma outra Application desta fase precisou do mesmo tratamento — só o `kube-prometheus-stack` traz CRDs grandes o bastante para estourar o limite.

### 11. Bug real (operacional, não de código): o operator descobre CRDs só na inicialização

Mesmo depois das decisões 9 e 10 corrigidas e a `Application` reportando `Synced`, o `Prometheus`/`Alertmanager` (as *custom resources*, já criadas com sucesso) nunca ganhavam um `StatefulSet` real — `kube-state-metrics`, `grafana` e todo o resto funcionando, mas nenhum pod `prometheus-...-0`/`alertmanager-...-0` aparecia, e a Application oscilava entre `Progressing`/`Degraded` indefinidamente. Causa raiz, só visível nos logs do próprio pod do operator: ele fez sua descoberta de capacidades da API **uma única vez, na inicialização** (`resource "prometheuses" (group: "monitoring.coreos.com/v1") not installed in the cluster`) — e esse boot aconteceu bem antes das CRDs existirem de verdade (elas só passaram a aplicar com sucesso depois da decisão 10, minutos depois). Como o `Deployment` do operator não mudou de spec em nenhuma das correções seguintes, o Kubernetes nunca teve motivo para recriar o pod — ele seguiu rodando com esse cache desatualizado indefinidamente, mesmo com a `Application` toda `Synced`.

Corrigido manualmente com `kubectl rollout restart deployment/kube-prometheus-stack-operator` — o pod novo redescobre a API do zero, encontra as CRDs (que essa altura já existiam de verdade) e cria os dois `StatefulSet`s em segundos. **Não é um bug de código deste repositório** — é um efeito colateral do processo iterativo de debug ao vivo desta sessão (múltiplas tentativas parciais de sync, cada uma progredindo um pouco mais que a anterior), não necessariamente algo que se repete num `apply` limpo do zero (onde, com as decisões 9-10 já no código, as CRDs devem aplicar de primeira, antes ou junto do Deployment do operator, sem a janela de 10+ minutos observada aqui). Fica como candidato a monitorar: se reaparecer num ciclo `destroy`→`apply` limpo, um sync-wave explícito nas CRDs (para o ArgoCD esperar `Established=True` antes de aplicar o restante) seria o próximo passo — não implementado agora por falta de confirmação de que o problema é estrutural, não só desta sessão.

### 12. Bug real: senha do Grafana regenerada a cada sync do ArgoCD

Mesmo com a stack toda `Healthy`, o login no Grafana falhava com a senha lida via `kubectl get secret kube-prometheus-stack-grafana` — inclusive relendo o secret na hora, imediatamente antes de tentar. Causa raiz: o chart gera a senha de admin do Grafana com uma função `randAlphaNum` no próprio template do Secret sempre que `grafana.adminPassword` não é definido — o que é seguro sob um `helm install`/`upgrade` de verdade (o *state* do Helm garante que o valor não muda numa reaplicação), mas **não** sob o ArgoCD: a Application aqui é renderizada via `helm template` sem estado, do zero, a cada sync — sem nenhum `lookup` contra o Secret já existente no cluster. Cada sync desta sessão (e foram muitos, por causa das decisões 9-11) gravou uma senha aleatória **nova** no Secret via Server-Side Apply, enquanto o pod do Grafana já rodando só lê esse valor **uma vez, na inicialização** — exatamente o mesmo padrão de "cache desatualizado" da decisão 11, mas para uma credencial em vez de uma descoberta de API. O valor que `kubectl get secret` mostra e o que está de fato ativo no Grafana em memória divergem silenciosamente a cada sync.

Corrigido gerando a senha uma única vez em estado real do Terraform (`resource "random_password" "grafana_admin"`, `terraform/envs/lab/argocd.tf`) e injetando via `helm.parameters` (`grafana.adminPassword`) — mesmo mecanismo já usado para os ARNs de IRSA role dos outros add-ons. Como o chart deixa de gerar a senha sozinho, o valor fica estável entre syncs; exposto via `terraform output -raw grafana_admin_password` (sensível), que passa a ser a fonte confiável — não mais `kubectl get secret`, que só reflete corretamente esse valor porque agora ele nunca muda, não porque seja a forma correta de lê-lo.

**Atualização (correção de segurança):** a correção acima estabilizava a senha, mas a entregava por um canal inseguro. `helm.parameters` de uma `Application` do ArgoCD vira parte do `spec` do recurso — a UI do ArgoCD mascara dados de Secret do Kubernetes por padrão, mas **não** mascara parâmetros Helm do spec da própria `Application`, então a senha ficava em texto plano para qualquer principal com RBAC de leitura sobre esse recurso (`kubectl get application kube-prometheus-stack -n argocd -o yaml`, ou o painel "Parameters" da UI). Diferente da senha do próprio ArgoCD — que já usava `set_sensitive` **e** só passava o hash bcrypt, nunca o texto plano (`resource "helm_release" "argocd"` no mesmo arquivo). Corrigido movendo o valor para um `kubernetes_secret_v1.grafana_admin` gerenciado pelo Terraform (num namespace `minitube-platform` agora também criado explicitamente pelo Terraform, não só via `CreateNamespace=true`), referenciado pelo chart via `grafana.admin.existingSecret`/`userKey`/`passwordKey` — o `helm.parameters` da Application passa a carregar só o *nome* do Secret, nunca o valor.

## Consequências

- `terraform/bootstrap-iam/main.tf`: novo `Sid AttachEbsCsiManagedPolicy` na policy inline única do permission set do operador.
- `terraform/envs/lab/variables.tf`: sizing `3/3/3`; 4 novas `*_chart_version` (ebs_csi_driver, kube_prometheus_stack, loki, promtail).
- `terraform/envs/lab/iam-platform.tf`: 2 novas IRSA roles (`ebs_csi_driver`, `grafana`); `terraform/envs/lab/outputs.tf`: outputs correspondentes.
- `terraform/envs/lab/argocd.tf`: `sourceRepos` do AppProject +3; 4 novas Applications multi-source (`ebs-csi-driver`, `kube-prometheus-stack`, `loki`, `promtail`); `depends_on` de `helm_release.argocd_apps` estendido às 2 novas policies IAM.
- `gitops/platform/{ebs-csi-driver,kube-prometheus-stack,loki,promtail}/`: novos, seguindo o padrão de subdiretório por componente já estabelecido na Fase 4.
- `app/api/main.py`, `app/api/requirements.txt`, `gitops/app/service.yaml`, `gitops/app/deployment.yaml`: instrumentação `/metrics`, porta nomeada, imagem `v0.1.3`.
- `terraform/envs/lab/scripts/validate-observability.sh`, `docs/runbooks/validate/validate-observability.md`: novos.
- Risco da decisão 4 (órfão de volume EBS) fica em aberto até o primeiro ciclo `destroy` real confirmar ou descartar — se confirmado, é candidato a um ADR 012 próprio, no mesmo padrão do ADR 010.
