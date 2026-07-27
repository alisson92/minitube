# 014 — Retune do orçamento de espera pela ALB após a carga concorrente da Fase 5

## Status

Aceito

## Contexto

`terraform apply` de `envs/lab` falhou em `null_resource.wait_for_alb`
(`terraform/envs/lab/cloudfront.tf`) com "timed out waiting for ALB
'minitube-app' to be provisioned by aws-load-balancer-controller". Uma
segunda execução do `apply`, logo em seguida, passou sem nenhuma mudança
de código — sintoma de falta de margem no orçamento de espera, não de um
bug de lógica.

O `null_resource.wait_for_alb` e seu poll via `aws elbv2 describe-load-balancers`
já existiam desde o [ADR 010](010-lbc-orphan-cleanup-and-alb-wait.md), com
orçamento de **5 minutos** (30 tentativas × 10s), calibrado numa sessão
anterior à Fase 5 com uma amostra de só 2 execuções reais (2min01s e
2min11s). Naquele momento, `helm_release.argocd_apps` bootstrapava 5
Applications: `app`, `platform`, `aws-load-balancer-controller`,
`external-dns` e `cert-manager`.

Desde então, o [ADR 011](011-observability-stack.md) (Fase 5 —
observabilidade) adicionou mais 3 Applications ao **mesmo**
`helm_release.argocd_apps`: `ebs-csi-driver`, `kube-prometheus-stack`
(Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics) e
`loki`. As 8 Applications hoje sincronizam concorrentemente no ArgoCD,
disputando CPU, memória e banda de pull de imagem nos mesmos 3 nós
`t3.medium` fixos (`eks_node_desired_size = var.eks_node_min_size =
var.eks_node_max_size = 3`, sem Cluster Autoscaler/Karpenter) -- exatamente
enquanto o `aws-load-balancer-controller` também precisa subir, completar
*leader election* e só então reconciliar o `Ingress` de `gitops/app/` para
provisionar a ALB. O orçamento de 5 minutos do ADR 010 nunca foi revisado
depois desse aumento de carga concorrente introduzido pelo ADR 011 -- a
causa raiz é essa lacuna de retune, não uma falha do mecanismo de poll em
si (que continua correto: `depends_on` sozinho não espera reconciliação
in-cluster, só ordena chamadas de API).

## Decisões

### 1. Orçamento elevado de 5min para 15min (900s)

Sem uma segunda rodada de medições reais (o objetivo aqui é dar margem
suficiente para a variância observada, não recalibrar por amostragem
extensa), 900s foi escolhido por ser 3x o orçamento anterior -- folga
suficiente para a concorrência de bootstrap atual sem deixar o `apply`
preso por tempo desproporcional caso o problema seja outro (ex.: o
`aws-load-balancer-controller` genuinamente quebrado). Timeout de 15min
neste ponto ainda é uma fração pequena do `apply` completo de um ambiente
do zero.

### 2. Loop reescrito por tempo decorrido, com log de progresso

O `for i in $(seq 1 30)` (contagem fixa de tentativas) virou um `while`
sobre segundos decorridos (`deadline_seconds=900`, `interval_seconds=10`).
Mais fácil de retunar no futuro (um único valor em segundos, não uma conta
tentativas × intervalo) e cada iteração agora emite uma linha em `stderr`
com o tempo decorrido -- evita que o `apply` fique em silêncio total por
até 15 minutos, alinhado ao princípio de soluções observáveis
(`docs/engineering-standards.md`).

**Alternativa descartada:** manter a contagem fixa de tentativas só
aumentando o número. Rejeitada por ser menos legível (o orçamento total
fica implícito na multiplicação de dois números) e por não abrir espaço
natural para o log de progresso.

## Consequências

- `terraform/envs/lab/cloudfront.tf`: script do `null_resource.wait_for_alb`
  reescrito (orçamento 900s, loop por tempo decorrido, log de progresso);
  comentário do recurso passa a referenciar este ADR além do 010.
- Validação funcional real (o novo orçamento realmente elimina a
  intermitência) depende do próximo ciclo `apply` completo do ambiente --
  não executado nesta sessão, que corrigiu o código com o `destroy` do
  ciclo anterior já em andamento. Se uma futura sessão observar novo
  timeout mesmo com os 900s, é sinal de que a causa não é mais só margem
  de tempo (voltar à hipótese de um problema real no
  `aws-load-balancer-controller`, não só retune de orçamento).
- 2ª calibragem do mesmo mecanismo desde o ADR 010 -- se uma 3ª ocorrer,
  considerar substituir o poll por AWS API por uma condição observável
  diretamente no cluster (ex.: aguardar `status.loadBalancer` no `Ingress`
  via `kubectl`), que reflete a reconciliação real em vez de inferir por
  um proxy externo.
