# 010 — Espera pela ALB no apply e eliminação do órfão do LBC no destroy

## Status

Aceito

## Contexto

Sessão de retomada da Fase 5. O `apply` inicial de `envs/lab` falhou (como já esperado e documentado desde o ADR 008 decisão 5) em `data.aws_lb.app_shared`, exigindo reexecução manual — comportamento incompatível com o objetivo de uma pipeline confiável, onde o `apply` precisa correr do início ao fim numa única execução, sem intervenção humana. O `destroy` em seguida travou de novo no mesmo problema já registrado **3 vezes** antes desta sessão (ADR 008 itens 7-9 → ADR 009 decisão 5 → ADR 009 decisão 6): a ALB e 2 security groups do `aws-load-balancer-controller` sobreviveram ao node group já destruído, bloqueando `DeleteSubnet`/`DetachInternetGateway` por `DependencyViolation`, e o namespace `argocd` ficou preso em `Terminating` por finalizers do LBC num `Ingress`/`TargetGroupBinding` sem controller vivo para removê-los.

Diferente das 3 ocorrências anteriores, desta vez os dois problemas foram corrigidos no código — mas o problema do `destroy` exigiu **quatro iterações reais** de causa raiz, cada uma só exposta ao testar de verdade um ciclo `apply`→`destroy` completo. Nenhuma delas apareceu em `terraform plan`/`validate` — reforça, mais uma vez, o princípio "existe vs. funciona" (`docs/engineering-standards.md` §11).

## Decisões

### 1. `null_resource` com poll via AWS CLI antes de `data.aws_lb.app_shared`

O `depends_on = [helm_release.argocd_apps]` já existente garante só a ordem das chamadas de API do Terraform — não que o `aws-load-balancer-controller` já tenha reconciliado o `Ingress` e provisionado a ALB dentro do cluster nesse instante. Como `helm_release.argocd_apps` retorna assim que as Applications são criadas (bem antes do ArgoCD sincronizar e o LBC agir), o `data.aws_lb.app_shared` quase sempre falhava no primeiro `apply` de um ambiente novo.

Corrigido com `resource "null_resource" "wait_for_alb"` (`terraform/envs/lab/cloudfront.tf`), com `depends_on = [helm_release.argocd_apps]` e um `provisioner "local-exec"` que faz poll de `aws elbv2 describe-load-balancers --names minitube-app` (10 tentativas, 10s entre elas, timeout total de 5 min) antes de `data.aws_lb.app_shared` ser lido. `interpreter = ["/bin/bash", "-c"]` explícito — o default do provisioner (`/bin/sh -c`) resolve para `dash` neste ambiente, que não entende `set -o pipefail`, quebrando o script na primeira tentativa real.

**Alternativa descartada:** `time_sleep` com duração fixa, mesmo mecanismo já usado no ADR 009 decisão 2. Rejeitada porque o tempo de provisionamento da ALB varia — um valor fixo ou é curto demais (repete a mesma falha) ou desperdiça tempo em toda run. Validado nesta sessão em dois `apply`s completos do zero: esperou 2min01s e 2min11s respectivamente, sem nenhuma falha.

**Consequência prática:** novo provider `hashicorp/null` (`~> 3.2`), pinado em `terraform/envs/lab/versions.tf`.

### 2. `AppProject` separado num `helm_release` próprio, destruído por último

O finalizer `resources-finalizer.argocd.argoproj.io` (decisão 3 abaixo) faz o ArgoCD podar os recursos de uma Application antes de remover seu CR — mas isso exige que a `AppProject` referenciada pela Application (`spec.project`) ainda exista durante toda a poda. Com `projects.minitube-platform` e `applications.platform` no **mesmo** `helm_release.argocd_apps`, `helm uninstall` apagou os dois ao mesmo tempo, sem ordem garantida entre kinds de CRD diferentes — na prática, a `AppProject` sumia antes da poda da `platform` terminar, e o ArgoCD falhava permanentemente com `error getting app project "minitube-platform": ... not found`, travando a Application `platform` (dona do `Ingress` do ArgoCD) para sempre.

Corrigido extraindo o bloco `projects` para `resource "helm_release" "argocd_project"` (`terraform/envs/lab/argocd.tf`), com `depends_on = [helm_release.argocd]` só (criado antes de `argocd_apps`, sem nenhuma restrição real de ordem). `helm_release.argocd_apps` ganha `depends_on = [..., helm_release.argocd_project]` — no destroy, isso inverte para: `argocd_apps` (e as Applications que ele contém) destruído **primeiro**, `argocd_project` (a `AppProject`) destruído **depois**. A `AppProject` passa a sobreviver a toda a janela de poda das Applications que a referenciam.

### 3. Finalizer `resources-finalizer.argocd.argoproj.io` nas Applications `app` e `platform`

Nenhuma das 5 Applications tinha `metadata.finalizers`. Sem esse finalizer, apagar a Application CR (o que `helm uninstall` faz no `destroy`) **não** aciona o ArgoCD a podar os recursos que ela gerencia primeiro — o `Ingress`/`TargetGroupBinding` compartilhando a ALB (decisão 4 do ADR 008) ficavam órfãos: nem o ArgoCD (objeto já removido) nem o LBC (nunca notificado) tinham como desprovisionar a ALB antes do `aws_eks_node_group` ser destruído.

Corrigido adicionando `finalizers = ["resources-finalizer.argocd.argoproj.io"]` a `applications.app` e `applications.platform` — as duas donas dos `Ingress` que compartilham a ALB. Com o finalizer, apagar essas Applications passa a **bloquear** até o ArgoCD podar os recursos gerenciados. `helm_release.argocd_apps` ganhou `wait = true` (já era o default do provider, agora explícito) e `timeout = 600` (antes sem valor, caindo no default de 300s) para dar margem a essa poda + a limpeza da ALB na AWS.

**Alternativa descartada:** script de pre-destroy (`kubectl delete ingress --all -A` + pausa de `syncPolicy`), já cogitado nos ADRs 008/009. Rejeitada por não ser declarativa — exigiria lembrar de rodar um passo extra antes de todo `destroy`, o oposto do objetivo desta sessão.

### 4. Caminho de rede inteiro (NAT + IGW + rotas + associações) precisa sobreviver à poda

Com as decisões 2-3 aplicadas, o primeiro `destroy` de teste completo travou de novo — desta vez em `helm_release.argocd_apps` propriamente dito, por **10 minutos** (o timeout da decisão 3), até falhar com `context deadline exceeded`. Diagnóstico: nada no `helm_release.argocd_apps` referencia `aws_nat_gateway.lab`, então o Terraform o destruiu em paralelo, no primeiro minuto do `destroy` — cortando o acesso dos pods do LBC (subnet privada) à API da AWS bem no meio da poda (`dial tcp ...:443: i/o timeout` nos logs do LBC).

Primeira correção — `depends_on` do NAT gateway + sua rota privada + associações das subnets privadas — **não bastou**: o NAT gateway sobreviveu, mas sua própria subnet é *pública*, e a rota dela até o Internet Gateway (`aws_route.public_internet_gateway`) e as associações da subnet pública não tinham nenhuma proteção — foram destruídas nos primeiros segundos do `destroy` de qualquer forma. O NAT gateway ficou de pé, porém isolado, sem caminho nenhum até a internet — mesmo sintoma (`i/o timeout`), causa ligeiramente diferente.

Corrigido fixando o caminho de rede **completo** — lado privado (`aws_nat_gateway.lab`, `aws_route.private_nat_gateway`, `aws_route_table_association.private`) e lado público do qual o NAT gateway depende (`aws_internet_gateway.lab`, `aws_route.public_internet_gateway`, `aws_route_table_association.public`) — no `depends_on` de `helm_release.argocd_apps`. Em ambas as direções essa dependência é correta, não só um workaround de destroy: os nodes/pods já precisam desse caminho completo desde a criação, para puxar imagens e falar com a API da AWS.

### 5. Policies IAM do LBC e do external-dns também precisam sobreviver à poda

Com as decisões 2-4 aplicadas, um terceiro `destroy` de teste completo travou de novo, mesmo padrão de 10 minutos — mas desta vez os logs do LBC mostravam `AccessDenied: ... is not authorized to perform: elasticloadbalancing:DescribeTargetHealth` em vez de timeout: a rede já funcionava. A *role* IAM do LBC (`aws_iam_role.aws_load_balancer_controller`) já estava implicitamente protegida — seu ARN é referenciado direto nos `values` de `helm_release.argocd_apps` (`helm.parameters` da Application `aws-load-balancer-controller`), criando uma dependência implícita. Mas a **policy** inline (`aws_iam_role_policy.aws_load_balancer_controller`) é um recurso separado, não referenciado em lugar nenhum — nada a protegia, e ela foi destruída em paralelo enquanto o LBC ainda tentava desregistrar targets e apagar a ALB.

Corrigido adicionando `aws_iam_role_policy.aws_load_balancer_controller` ao `depends_on`. `aws_iam_role_policy.external_dns` recebeu o mesmo tratamento preventivamente — o external-dns precisa dessa policy para apagar o registro Route 53 de `argocd.<domínio>` quando o `Ingress` correspondente é podado; sem ela, o registro ficaria órfão silenciosamente (não bloqueia o `destroy`, mas é uma sujeira que o padrão já estava causando em outros pontos). `aws_iam_role_policy.cert_manager` não recebeu o mesmo tratamento — nesta arquitetura o cert-manager nunca chega a emitir um `Certificate` real (ADR 008 decisão 8), então não há chamada de API sua em voo durante a poda.

Com as cinco decisões aplicadas, um quarto ciclo `apply`→`destroy` completo, do zero, rodou sem nenhuma intervenção manual em nenhuma das duas pontas — `helm_release.argocd_apps` destruiu em **29 segundos** (antes, quando não travava por completo, chegava a ficar preso por 10+ minutos).

## Consequências

- `terraform/envs/lab/cloudfront.tf`: `resource "null_resource" "wait_for_alb"`; `data.aws_lb.app_shared` depende dele em vez de `helm_release.argocd_apps` diretamente.
- `terraform/envs/lab/versions.tf`: provider `hashicorp/null ~> 3.2` adicionado.
- `terraform/envs/lab/argocd.tf`: novo `resource "helm_release" "argocd_project"` (só o bloco `projects`); `applications.app`/`applications.platform` ganham `finalizers`; `helm_release.argocd_apps` ganha `wait = true`, `timeout = 600`, e `depends_on` cobrindo `argocd_project` + todo o caminho de rede (NAT/IGW/rotas/associações, público e privado) + as policies IAM do LBC e do external-dns.
- Validado nesta sessão: 4 ciclos completos `apply`→`destroy` do zero, cada um expondo e corrigindo uma causa raiz real, até o quarto rodar limpo de ponta a ponta — `scripts/validate-cloudfront-dns-tls.sh` (9 checagens) passou em todos os `apply`s bem-sucedidos; limpeza total confirmada via API AWS direta após cada `destroy` final.
- Encerra a dívida técnica registrada em ADR 008 (itens 7-9, 15) e ADR 009 (decisões 5 e 6) — 4ª ocorrência do bug original do LBC, agora corrigida no código, mais 3 causas-raiz adicionais (AppProject, rede, IAM) descobertas e corrigidas só ao testar o fix de verdade.
