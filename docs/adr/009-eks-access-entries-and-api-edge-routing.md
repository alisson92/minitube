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

### 6. Terceira ocorrência do órfão do LBC — desta vez bloqueando a exclusão do namespace `argocd`

Sessão separada, fora do escopo das decisões 1-5 (nenhum código novo, pura recuperação operacional). Um `terraform apply` inicial falhou — como esperado e já documentado no próprio `cloudfront.tf` — em `data.aws_lb.app_shared`, porque a ALB ainda não existia (chicken-and-egg entre `helm_release.argocd_apps` e a leitura da ALB na mesma run). O `terraform destroy` disparado em seguida travou pelo mesmo padrão da decisão 5 acima e dos itens 7-9 do ADR 008: a ALB e os security groups do LBC (`k8s-minitube-*`, `k8s-traffic-minitubelab-*`) sobreviveram ao node group já destruído, bloqueando com `DependencyViolation` o detach do IGW ("has some mapped public address(es)", por causa das ENIs da ALB com IP público) e a exclusão das duas subnets públicas.

Recuperado manualmente: `aws elbv2 delete-load-balancer` na ALB órfã; os dois security groups apagados via `aws ec2 delete-security-group` — um deles só liberou depois de um `aws ec2 revoke-security-group-ingress` numa regra do próprio security group do cluster EKS que o referenciava (`elbv2.k8s.aws/targetGroupBinding=shared`).

Um segundo `terraform destroy` então travou numa variante nova da mesma causa raiz: o namespace `argocd` ficou preso em `Terminating` porque um `Ingress` e um `TargetGroupBinding` dentro dele carregavam finalizers do LBC (`group.ingress.k8s.aws/minitube`, `elbv2.k8s.aws/resources`) que só o controller (já morto, sem node group) removeria. Diferente do ADR 008 item 8 (mesma classe de problema): desta vez o próprio `kubectl patch` para remover o finalizer foi bloqueado pelo `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration` do LBC, ainda registrado no cluster mas sem endpoint vivo (`failurePolicy` padrão bloqueia a chamada em vez de deixar passar) — precisou apagar as duas webhook configurations antes do `kubectl patch --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'` funcionar.

**Erro operacional à parte, registrado para não repetir:** ao tentar retomar o `destroy` interrompido, foi disparado um `terraform apply -auto-approve` **sem a flag `-destroy`** — esse comando por padrão converge para o que está declarado no `.tf`, ou seja, teria **recriado** IGW/subnets/NAT/cluster já destruídos. Interrompido a tempo (ainda na fase de `refresh`/cálculo do plano, nenhum `Creating...` chegou a rodar; confirmado via `describe-*` na AWS que nada foi criado). Lição: depois de qualquer `destroy` interrompido ou com erro parcial, sempre gerar um novo `terraform plan -destroy -out=<arquivo>` e aplicar exatamente esse plan file (`terraform apply <arquivo>`) — nunca reexecutar um `apply`/`destroy` genérico sem plan file, mesmo com `-auto-approve`, porque nesse modo é o comando que decide a direção (criar vs. destruir), não o operador.

Esta é a **3ª ocorrência** da mesma causa raiz (ADR 008 itens 7-9 → ADR 009 decisão 5 → aqui), agora também travando o namespace do ArgoCD, não só a camada de rede. Segue **sem automação** — os dois candidatos já registrados (finalizer `resources-finalizer.argocd.argoproj.io` nas Applications do LBC, ou script de pre-destroy que pausa `syncPolicy` + apaga `Ingress`/webhooks do LBC antes do `terraform destroy` tocar no node group) precisam ser implementados antes do próximo ciclo apply→destroy.

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
- Decisão 6: nenhuma mudança de código — recuperação 100% manual via `aws cli`/`kubectl` contra a infraestrutura já existente. Ambiente confirmado destruído ao final (cluster EKS, VPC, NAT, ALB, security groups do LBC, EIPs — todos ausentes via API AWS direta). Prioridade elevada para a automação da limpeza pré-destroy na próxima sessão.
