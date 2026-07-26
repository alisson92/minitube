# 012 — HPA por CPU no Deployment `api`, metrics-server via GitOps

## Status

Aceito

## Contexto

O `CLAUDE.md` já previa, na Fase 6, decidir entre HPA e Cluster Autoscaler/Karpenter "guiado por carga real do k6" — deliberadamente adiado da Fase 5 (ADR 011, decisão 1) para não ser engenharia antecipada sem dado.

O dado chegou nesta sessão: o teste de breakpoint (`load/k6/breakpoint.js`), rodado de dentro da própria VPC via `load/run-breakpoint-from-ec2.sh` (ver `docs/runbooks/run-k6-breakpoint.md` para o porquê de precisar rodar de dentro da AWS — testes locais via WSL2/rede residencial abortavam cedo demais por ruído de rede, mascarando qualquer sinal real), encontrou um gargalo genuíno e confirmado por três fontes independentes na mesma janela de tempo (Prometheus + `kube_pod_container_status_restarts_total`):

- **CPU do pod `api` sobe de forma monotônica e satura ~98% do `limits.cpu: 500m`** exatamente no momento em que o teste aborta.
- **A latência interna da própria API** (`http_request_duration_seconds`, instrumentada via `prometheus-fastapi-instrumentator`, medida dentro do pod — não pelo k6) fica estável em ~95ms de p95 por mais de 6 minutos e só dispara nos últimos ~60 segundos, acompanhando a curva de CPU.
- **Memória fica estável** (~100-120MB de um limite de `256Mi`) e **os 3 nodes do node group ficam com folga enorme** (o mais ocupado chega a só ~35% de utilização) — descartando memória e capacidade de node como causa.

Ou seja: o teto é o limite de CPU da única réplica, não o node group. Isso decide a escolha entre HPA e Cluster Autoscaler/Karpenter com dado real, não suposição.

## Decisões

### 1. HPA por CPU, não Cluster Autoscaler/Karpenter

Cluster Autoscaler/Karpenter resolveria falta de capacidade de *node* — não é o problema encontrado (nodes com folga confirmada). HPA por CPU no Deployment `api` ataca exatamente o gargalo medido: mais réplicas distribuem a mesma CPU agregada entre mais pods, dentro de nodes que já têm espaço de sobra. Cluster Autoscaler/Karpenter continua fora de escopo até o HPA algum dia escalar réplicas o suficiente para esgotar os 3 nodes atuais — cenário distante da folga observada.

### 2. metrics-server via GitOps (Application multi-source), não `aws_eks_addon`

HPA por CPU depende da API `metrics.k8s.io`, que o cluster não tinha (confirmado: nenhum `aws_eks_addon`, nenhuma Application ArgoCD, zero menções no repositório antes desta sessão). Instalado como mais um subdiretório `gitops/platform/metrics-server/` + Application multi-source, a mesma forma já usada para `aws-load-balancer-controller`/`external-dns`/`cert-manager` (Fase 4) e `ebs-csi-driver` (Fase 5) — este último já havia registrado a mesma justificativa (ADR 011, decisão 3): manter um único mecanismo de instalação de add-on de plataforma no repositório, em vez de dois mecanismos concorrentes (`aws_eks_addon` da AWS vs. GitOps).

Sem IRSA role, sem PVC, sem `finalizers` — metrics-server só faz *scraping* local dos `kubelet`s dos próprios nodes, nenhuma chamada à API da AWS. Mesma forma mínima já usada por `promtail` (Fase 5).

### 3. `--kubelet-insecure-tls`

Os certificados de *serving* do `kubelet` em nodes gerenciados pelo EKS não carregam os SANs que a verificação TLS padrão do metrics-server exige — um gap conhecido e documentado pela própria AWS para este componente. A alternativa (configurar uma CA própria e reemitir certificados de `kubelet` compatíveis) é desproporcional para um cluster efêmero, recriado do zero a cada sessão. Aceito como trade-off padrão da comunidade: esse tráfego nunca sai do plano de controle interno do cluster (VPC privada, security groups do EKS) — não é uma superfície exposta externamente.

### 4. `minReplicas: 2` / `maxReplicas: 6` / `averageUtilization: 70`

- **`minReplicas: 2`**: elimina o ponto único de falha que `replicas: 1` representa hoje — um dos gatilhos de alerta obrigatório do próprio padrão de trabalho deste projeto (`replicas: 1` sem PDB). Só faz sentido combinado com a decisão 5 abaixo.
- **`maxReplicas: 6`**: ~6x a carga que saturou uma única réplica no teste real (~125-130 req/s combinados de `/api/healthz` + `/api/videos/{id}`, interpolado a partir do ponto da rampa onde a CPU saturou). O node group (3× `t3.medium`, folga confirmada por dado real) tem espaço de sobra para isso sem se aproximar de qualquer limite de node.
- **`averageUtilization: 70`**: valor-padrão consolidado na comunidade Kubernetes. Calculado sobre `requests.cpu: 100m` (não o `limits.cpu: 500m` que satura) — dispara scale-out em ~70m de uso médio por pod, bem antes de qualquer réplica se aproximar do limite que causou a degradação observada.

### 5. PDB (`minAvailable: 1`) incluído junto com o HPA, não como item separado

Nenhum PodDisruptionBudget existia no repositório antes desta sessão (confirmado por busca). Como o HPA leva o Deployment a rodar com múltiplas réplicas pela primeira vez, um PDB mínimo é extensão direta e de baixo risco do mesmo trabalho — sem ele, uma rotação de node (spot, sujeito a interrupção) ou um `rollout` concorrente poderiam derrubar todas as réplicas ao mesmo tempo, anulando o ganho de disponibilidade que `minReplicas: 2` pretende dar.

### 6. `ignoreDifferences` no campo `/spec/replicas` da Application `app`

Toda Application deste projeto roda com `syncPolicy.automated.selfHeal = true`. Sem tratamento, o ArgoCD reverteria `spec.replicas` do Deployment `api` de volta ao valor estático do manifesto a cada sync, brigando com o HPA (que ajusta esse mesmo campo em tempo real via `scale` subresource). Resolvido com `ignoreDifferences` (`terraform/envs/lab/argocd.tf`, bloco `applications.app`) apontando para `apps/Deployment`, `name: api`, `jsonPointers: ["/spec/replicas"]` — o padrão documentado pela própria ArgoCD para exatamente este cenário (Deployment gerenciado por HPA). `gitops/app/deployment.yaml` mantém `replicas: 1` como está, valendo só como contagem inicial antes do HPA assumir o campo.

## Validação

Ver `docs/runbooks/run-k6-breakpoint.md` para o resultado da revalidação com `load/run-breakpoint-from-ec2.sh` após esta implementação — o teste funcional deste entregável é o HPA escalando réplicas sob carga real e o ponto de quebra subindo, não apenas o `apply` limpo e os objetos existindo com os atributos certos (padrão de validação funcional pós-apply, `docs/engineering-standards.md` seção 11).
