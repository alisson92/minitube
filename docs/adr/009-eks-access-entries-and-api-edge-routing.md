# 009 — Access entries do EKS e roteamento de borda da API

## Status

Aceito

## Contexto

Sessão de retomada, com o objetivo de iniciar a Fase 5 (Observabilidade). Recriar `envs/lab` do zero (ciclo normal de efemeridade) travou logo no `apply` inicial, antes de qualquer código novo de Fase 5 — motivando esta sessão inteira ser sobre bugs pré-existentes das Fases 1 e 4, nenhum deles pego pela suíte de validação funcional até agora, porque nenhuma sessão anterior tinha exercitado `/api/*` através do CloudFront de ponta a ponta com uma requisição pública real.

## Decisões

### 1. `bootstrap_cluster_creator_admin_permissions = false`

`terraform apply` falhou com `409 ResourceInUseException` criando `aws_eks_access_entry.operator`: quando `bootstrap_cluster_creator_admin_permissions = true`, o EKS cria automaticamente uma access entry oculta para a identidade que chama `CreateCluster`. Como quem rodou o `apply` desta vez foi o próprio `cloudlab-operator` (a mesma identidade de `var.operator_role_arn`), essa access entry automática colidiu com a explícita (`aws_eks_access_entry.operator`, criada desde o ADR 004 para cobrir sessões em que o cluster nasce via CloudShell/root).

Esse mesmo conflito já tinha aparecido no ADR 007 (item 11) e ali foi resolvido pontualmente via `terraform import`. Desta vez a correção é estrutural: `terraform/envs/lab/eks.tf` desliga `bootstrap_cluster_creator_admin_permissions`. Sem ele, o EKS nunca cria a access entry automática — o acesso ao cluster passa a ser **100% declarado pelo Terraform**, independente de quem roda o `apply`. Confirmado via `get_provider_details` (MCP do Terraform) que o argumento força recriação do cluster (`# forces replacement`) — não é uma mudança in-place, então a correção exigiu destruir e recriar o ambiente inteiro nesta sessão (aceitável, sessão ainda não tinha nada validado).

### 2. `time_sleep` de 30s antes do primeiro recurso `kubernetes_*`

Consequência direta da decisão 1: `CreateAccessEntry`/`AssociateAccessPolicy` retornam sucesso da API em ~1s, mas o *authorizer* do control plane do EKS leva alguns segundos a mais para de fato aceitar o novo principal — sem nenhum `describe`/wait exposto pela API para confirmar a propagação. Com `bootstrap_cluster_creator_admin_permissions = true`, isso nunca aparecia por acidente: a permissão do criador nascia junto do próprio `CreateCluster` (~10 minutos, tempo de sobra pra propagar). Com o acesso 100% explícito (decisão 1), a corrida ficou exposta: `kubernetes_namespace_v1.argocd` falhava com `403 Forbidden` mesmo já tendo `depends_on` nos dois recursos de access entry (a dependência garante ordem de **chamada de API**, não de propagação real).

Corrigido com `resource "time_sleep" "operator_access_propagation"` (`terraform/envs/lab/argocd.tf`), `depends_on` nos dois recursos de access entry, `create_duration = "30s"`, e todo recurso `kubernetes_*`/`helm_release` subsequente encadeado nele (via a referência existente a `kubernetes_namespace_v1.argocd.metadata[0].name`).

### 3. Rotas da API sob `/api` — decisão do lado da aplicação, não da borda

`cloudfront.tf`'s `ordered_cache_behavior { path_pattern = "/api/*" }` encaminha o path pro ALB **sem reescrita** — o `aws-load-balancer-controller` também não reescreve path. A API (`app/api/main.py`) só respondia rotas na raiz (`/healthz`, `/videos`), então toda chamada pública em `/api/*` batia 404, nunca detectado porque `validate-cloudfront-dns-tls.sh` faz upload via `kubectl port-forward` direto no Service, nunca através do CloudFront/ALB.

Escolhida a correção do lado da aplicação (`APIRouter(prefix="/api")`) em vez de reescrever o path na borda (CloudFront Function) — mantém a lógica de rotas visível e testável no próprio código da API, sem uma camada de reescrita escondida na infra que só se descobre lendo Terraform. Exigiu: bump de imagem pra `v0.1.2` (ECR), ajuste do `readinessProbe`/`livenessProbe` do Deployment e da annotation `healthcheck-path` do Ingress (que também estava sem valor — o default do LBC é `GET /`, que a API nunca respondeu, deixando o target group `unhealthy` e todo request `502`), e atualização dos paths nos dois scripts de validação existentes.

### 4. Origin do CloudFront aponta pra um registro Route 53 próprio, não pro DNS bruto da ALB

Mesmo com as decisões 1-3 corrigidas, `/api/*` via CloudFront ainda devolvia `502` — mas direto na ALB (`curl -k`) funcionava. Causa: CloudFront faz verificação de hostname do TLS contra o `domain_name` configurado no origin; `cloudfront.tf` apontava `data.aws_lb.app_shared.dns_name` (o nome bruto gerado pela AWS), mas o certificado que a ALB serve é o wildcard `*.${var.domain_name}` (mesmo ACM da annotation `certificate-arn` do Ingress) — sem SAN para o nome bruto da ALB. O handshake TLS falhava antes mesmo da requisição HTTP ser encaminhada.

Corrigido com `aws_route53_record.alb_origin`, um alias A record em `alb-origin.${var.domain_name}` apontando pra ALB — coberto pelo mesmo certificado wildcard. `cloudfront.tf`'s origin `alb-api` passa a apontar pra esse registro em vez do DNS bruto. Alternativa descartada: `origin_protocol_policy = "http-only"` (mais simples, uma linha) — rejeitada por remover TLS do trecho CloudFront↔ALB sem necessidade, quando um registro DNS próprio resolve sem abrir mão de criptografia ponta a ponta.

### 5. Procedimento de `destroy` reforça a dívida técnica do ADR 008 (item 15) — ainda não automatizada

O mesmo problema do ADR 008 (Applications do ArgoCD sem o finalizer `resources-finalizer.argocd.argoproj.io`, deixando a ALB/security groups do LBC órfãos se o `destroy` matar o node group antes do controller apagar os recursos) se repetiu nesta sessão. Desta vez o procedimento manual usado (apagar os `Ingress` antes do `terraform destroy`, enquanto o LBC ainda está de pé) expôs uma nuance nova: o `selfHeal` automático das Applications `app`/`platform` desfaz a exclusão manual do `Ingress`, tratando-a como *drift* — a ALB nunca chegava a ser removida na primeira tentativa. Corrigido pausando `spec.syncPolicy` (`kubectl patch ... -p '{"spec":{"syncPolicy":null}}'`) das duas Applications antes de apagar os `Ingress`, só então rodando o `terraform destroy`.

Efeito colateral encontrado: apagar a ALB manualmente antes do `destroy` quebra `data "aws_lb" "app_shared"` (lida incondicionalmente em qualquer operação do Terraform, inclusive `destroy`) — contornado com o mesmo procedimento do ADR 008 item 13 (mover `cloudfront.tf` pra fora do diretório + remover temporariamente os 2 outputs que dependem dele, rodar o `destroy`, restaurar os arquivos via `git checkout`).

**Ainda não corrigido no código** — candidatos já registrados no ADR 008 seguem válidos: (a) adotar o finalizer nas Applications que gerenciam recursos do LBC (destroy mais lento, porém automático); (b) um script de pre-destroy que roda `kubectl delete ingress --all -A` + pausa o `syncPolicy` + aguarda a ALB sumir, antes de qualquer `terraform destroy` tocar no node group.

## Consequências

- `terraform/envs/lab/eks.tf`: `access_config.bootstrap_cluster_creator_admin_permissions = false`.
- `terraform/envs/lab/argocd.tf`: `resource "time_sleep" "operator_access_propagation"`; `kubernetes_namespace_v1.argocd` passa a depender dele em vez dos recursos de access entry diretamente.
- `terraform/envs/lab/versions.tf`: provider `hashicorp/time ~> 0.14` adicionado.
- `terraform/envs/lab/cloudfront.tf`: `resource "aws_route53_record" "alb_origin"`; origin `alb-api` aponta pra ele em vez de `data.aws_lb.app_shared.dns_name`.
- `app/api/main.py`: rotas movidas para `APIRouter(prefix="/api")`.
- `gitops/app/deployment.yaml`: `readinessProbe`/`livenessProbe` em `/api/healthz`; imagem `v0.1.2`.
- `gitops/app/ingress.yaml`: annotation `alb.ingress.kubernetes.io/healthcheck-path: /api/healthz`.
- `terraform/envs/lab/scripts/{validate-cloudfront-dns-tls,validate-transcoding}.sh` e os runbooks correspondentes: paths atualizados para `/api/*`.
- `docs/runbooks/access-argocd-ui.md` (novo): comando para buscar a senha inicial do ArgoCD, regenerada a cada sessão.
- PR #14 (`fix/eks-access-entry-and-api-healthcheck`), validado nesta sessão via `-var argocd_gitops_revision=<branch>` (padrão do ADR 007, decisão 5) antes do merge, depois revertido para o default (`main`) — o merge por si só disparou o self-heal do ArgoCD para o estado corrigido, sem `terraform apply` adicional.
