# 008 — CloudFront, DNS/TLS e add-ons de plataforma

## Status

Aceito

## Contexto

Critério de conclusão da Fase 4 (`CLAUDE.md`): `app.<domínio>` servindo vídeo via CDN com HTTPS válido. A fase foi dividida em 2 PRs por causa de uma dependência externa não instantânea: a delegação manual de NS records pelo usuário no registrador do domínio raiz. O primeiro PR (`feat/route53-zone-and-cert`, `terraform/bootstrap/dns.tf`) criou a hosted zone Route 53 (`minitube.projetodevops.com.br`) e o certificado ACM wildcard (`*.minitube.projetodevops.com.br`), ambos persistentes — confirmados nesta sessão, de forma independente, como delegados (`dig`) e `ISSUED` (`aws acm describe-certificate`), antes de qualquer código deste PR ser escrito. Este ADR cobre o segundo PR: CloudFront, as 3 IRSA roles de plataforma, os add-ons via GitOps e os Ingresses.

## Decisões

### 1. `app.<domínio>` = alias do CloudFront = critério de conclusão da fase

`terraform/envs/lab/cloudfront.tf` cria `aws_route53_record.app` como alias A record apontando para a distribution — via Terraform, não `external-dns`, já que o CloudFront é ele próprio um recurso Terraform (sem motivo para delegar essa descoberta a um controller in-cluster).

### 2. `argocd.<domínio>` vai direto à ALB, não via CloudFront

ArgoCD é ferramenta operacional interna — não se beneficia de cache de borda, e manter o CloudFront restrito a servir HLS por padrão + `/api/*` sob demanda mantém seu comportamento dinâmico mínimo. Roteado por `gitops/platform/argocd/ingress.yaml` + `external-dns` (a ALB é provisionada dinamicamente pelo controller, então só um controller in-cluster sabe seu endpoint atual a cada sessão — um `aws_route53_record` estático no Terraform não serviria aqui, ao contrário do registro do CloudFront).

### 3. Um único certificado ACM (us-east-1) serve CloudFront e ALB

Já previsto no comentário de `terraform/bootstrap/dns.tf` desde o PR #1. CloudFront exige `us-east-1` independente da região dos origins; a região deste projeto já é `us-east-1` por padrão.

### 4. IngressGroup compartilhado — uma única ALB para app e ArgoCD

`gitops/app/ingress.yaml` e `gitops/platform/argocd/ingress.yaml` usam `alb.ingress.kubernetes.io/group.name: minitube`, provisionando uma ALB só em vez de duas (custo: ~$0,0225/h fixo por ALB). Ambos fixam `alb.ingress.kubernetes.io/load-balancer-name: minitube-app` (idêntico nos dois) para dar à ALB um nome prévisível, em vez de depender das tags auto-geradas pelo controller.

### 5. `data "aws_lb"` por nome, não por tags — e a dependência circular que isso expõe

A ALB é provisionada dinamicamente pelo aws-load-balancer-controller a partir do Ingress, não pelo Terraform. `terraform/envs/lab/cloudfront.tf` precisa do seu DNS name para o origin dinâmico do CloudFront — resolvido via `data "aws_lb" { name = "minitube-app" }` (nome fixo, decisão 4), não via filtro de tags (cuja sintaxe exata do controller não vale a pena arriscar adivinhar).

Isso expõe uma dependência circular real: no primeiro `apply` de um ambiente novo, `helm_release.argocd_apps` (que dispara a reconciliação do Ingress → ALB) e a leitura de `data.aws_lb.app_shared` acontecem na mesma execução — a ALB pode não existir ainda quando o data source é lido, mesmo com `depends_on` garantindo a ordem correta dos recursos Terraform entre si (o `depends_on` não espera o ArgoCD/controller *dentro* do cluster terminarem de convergir). Mitigação: mesma classe de solução já usada no ADR 007 (decisão 8) para o bootstrap do próprio ArgoCD — um `apply` em duas etapas, documentado no runbook: se `data.aws_lb.app_shared` falhar por a ALB ainda não existir, aguardar ~1-2 min e reaplicar.

### 6. Entrega dos 3 add-ons via ArgoCD Application multi-source

Cada add-on (aws-load-balancer-controller, external-dns, cert-manager) é uma Application dedicada em `terraform/envs/lab/argocd.tf` (chart `argocd-apps`, mesmo mecanismo do ADR 007) com dois `sources`: o chart Helm oficial remoto + um `ref: values` apontando para este próprio repositório Git (`gitops/platform/<addon>/values.yaml`). Permite injetar o ARN da IRSA role correspondente (conhecido só pelo Terraform) via `helm.parameters`, sem copiar nada manualmente para o Git.

**Alternativas descartadas:**
- **Kustomize `helmCharts:` (HelmChartInflationGenerator):** incompatível com `directory.recurse = true`, já em uso pela Application `platform` — adotar exigiria trocar o tipo de source dessa Application inteira, sem ganho real sobre a opção escolhida.
- **`helm template` pré-renderizado e commitado:** quebra "Git como única fonte de verdade" a cada bump de versão de chart — o ArgoCD nunca saberia que o chart mudou, risco de drift silencioso entre o commitado e o chart real.

### 7. `gitops/platform/` ganha subdiretório por add-on; Application `platform` exclui `values.yaml`

Os `values.yaml` de cada add-on não são manifests Kubernetes válidos sozinhos — a Application `platform` (modo `directory`, recursivo) ganha `directory.exclude = "**/values.yaml"` para não tentar sincronizá-los como recursos soltos. O único manifest plano real que a Application `platform` continua sincronizando nesta fase é `cert-manager/cluster-issuer.yaml`.

### 8. `ClusterIssuer` funcional, mas sem consumidor público real nesta fase

`gitops/platform/cert-manager/cluster-issuer.yaml` (DNS-01 via Route53) prova que a IRSA role do cert-manager e o RBAC funcionam ponta a ponta (ClusterIssuer chega a `Ready`), mas nenhum `Certificate` é emitido por ele ainda — CloudFront e a ALB usam o certificado ACM já existente e validado (persistente, PR #1). YAGNI: emitir um certificado Let's Encrypt real exigiria expor um endpoint HTTP-01 publicamente ou reusar o mesmo desafio DNS-01 sem ganho sobre o certificado ACM já validado. `hostedZoneID` é hardcoded no manifest (zona persistente, ID estável entre sessões) — mesmo padrão de `var.operator_role_arn`.

### 9. Ingress do app catch-all, sem `host:`

`gitops/app/ingress.yaml` não declara `host:` — o roteamento por domínio já é resolvido pelo alias do CloudFront (decisão 1); um `host: app.<domínio>` no Ingress colidiria semanticamente com isso, já que o tráfego que chega à ALB via CloudFront não carrega mais o hostname original em `/api/*` do jeito que o Ingress esperaria sem uma origin request policy adequada (já coberta via `Managed-AllViewerExceptHostHeader`).

### 10. Deploy key SSH do ArgoCD passa a persistir via SSM Parameter Store, não mais via `TF_VAR` a cada sessão

O ADR 007 (decisão 4) previa a chave privada só em `TF_VAR_argocd_repo_ssh_private_key`, sem persistência — o que, na prática, exigia gerar um novo par e recadastrar a deploy key no GitHub em **toda** sessão que recriasse `envs/lab`, contrariando o objetivo do projeto de que recriar o ambiente do zero seja indolor (`CLAUDE.md`, princípio 1: "se doer, o código ainda não está bom"). Discutido com o operador ao encontrar esse atrito na prática.

Corrigido: `terraform/bootstrap/ssm.tf` (novo) cria `aws_ssm_parameter.argocd_repo_ssh_private_key` (`SecureString`), persistente como os demais recursos de `bootstrap/` (ECR, zona Route 53, certificado). `lifecycle.ignore_changes = [value]` garante que só o primeiro `apply` (com um `TF_VAR_argocd_repo_ssh_private_key` real) grava o valor — todo `apply` seguinte, mesmo com a variável no default vazio, nunca tenta sobrescrevê-lo. `terraform/envs/lab/argocd.tf` passa a ler o valor via `data "aws_ssm_parameter" { with_decryption = true }`, não mais via variável sensível própria — a variável `argocd_repo_ssh_private_key` foi removida de `envs/lab/variables.tf`.

SSM Parameter Store foi escolhido (em vez de Secrets Manager) por não ter custo relevante no tier `Standard`/`SecureString` com a KMS key gerenciada `aws/ssm`, e por não ser uma ação restrita pelo `PowerUserAccess` do operador diário (ao contrário de qualquer recurso IAM) — sem necessidade de nenhuma concessão nova em `bootstrap-iam`. A deploy key em si continua sendo a escolha certa (ADR 007, decisão 4); só o mecanismo de persistência da chave privada mudou.

**Consequência prática:** a chave privada antiga (par gerado na Fase 3) não existia mais em disco em nenhum lugar — a deploy key órfã correspondente no GitHub foi removida e substituída por um novo par nesta sessão, cuja privada foi gravada uma única vez no parâmetro SSM. A partir de agora, nenhuma sessão futura precisa gerar ou cadastrar uma nova deploy key.

### 11. Novo prefixo IAM `minitube-platform-*`

`terraform/bootstrap-iam/main.tf` ganha a `Statement` `ManagePlatformIrsaRoles`, mesma forma de `ManageAppIrsaRoles` (ADR 006), escopada a `arn:aws:iam::<account>:role/minitube-platform-*` — prefixo distinto do `minitube-app-*` para manter as duas concessões auditáveis independentemente, mesmo com ações idênticas.

### 12. Quatro bugs reais encontrados na primeira sincronização real, todos corrigidos

Nenhum dos quatro apareceu em `terraform plan`/`validate` — só na sincronização de verdade do ArgoCD e no teste funcional real, reforçando o princípio "existe vs. funciona" (`docs/engineering-standards.md` §11):

1. **`AppProject.sourceRepos` não liberava os repositórios Helm dos add-ons.** As 3 Applications multi-source (decisão 6) falhavam com `InvalidSpecError: application repo ... is not permitted in project` — `sourceRepos` restringe **todo** source de toda Application do projeto, não só o Git. Corrigido adicionando os 3 URLs de chart (`eks-charts`, `external-dns`, `charts.jetstack.io`) à lista.
2. **`AppProject.destinations` não liberava `kube-system`.** O chart do cert-manager cria `Role`/`RoleBinding` de leader-election em `kube-system` por padrão do upstream, independente do namespace de instalação do resto do chart — `SyncFailed: namespace kube-system is not permitted in project`. Corrigido adicionando `kube-system` aos destinos permitidos.
3. **`aws-load-balancer-controller` não descobre o VPC ID sozinho neste cluster.** Sem `vpcId` explícito nos values, o controller tenta descobri-lo via IMDS na instância EC2 do node — falha (`context deadline exceeded`) e o pod entra em `CrashLoopBackOff`. Corrigido injetando `vpcId = aws_vpc.lab.id` via `helm.parameters` na Application (mesmo mecanismo já usado para o ARN da IRSA role — o valor muda a cada sessão, então não pode ser hardcoded em `values.yaml`).
4. **Prioridade de regras da ALB compartilhada invertida (`group.order`).** `gitops/app/ingress.yaml` (catch-all, sem `host:`) e `gitops/platform/argocd/ingress.yaml` (`host: argocd.<domínio>`) compartilham a mesma `IngressGroup` (decisão 4) — a regra catch-all tinha `group.order: "10"` (maior prioridade, número menor) contra `"20"` do Ingress do ArgoCD, então a ALB casava **toda** requisição — inclusive `argocd.<domínio>` — com o backend `api` antes de avaliar a regra específica de host. Sintoma: `argocd.<domínio>` respondia `404` do `uvicorn` (a API FastAPI), TLS válido, sem nenhum erro do lado do ArgoCD. Corrigido invertendo os valores: regras com `host:` específico precisam de número **menor** (maior prioridade) que o catch-all.

### 13. `terraform import` do access entry falhando por causa de um data source não relacionado

Ao reimportar `aws_eks_access_entry.operator` (mesmo conflito do ADR 007 item 11, que se repete sempre que o `cloudlab-operator`, não CloudShell/root, cria o cluster), o comando `terraform import` falhava mesmo com o recurso alvo correto — porque `terraform import` avalia **todos** os data sources do módulo como parte da preparação do state, incluindo `data.aws_lb.app_shared` (decisão 5), que não resolve numa VPC recém-criada sem ALB ainda. Contornado renomeando temporariamente `cloudfront.tf` (e removendo as 2 linhas de `outputs.tf` que o referenciam) durante o `import`, restaurando os arquivos logo em seguida — nenhuma mudança de código permanente, só um procedimento operacional a repetir se o mesmo cenário ocorrer de novo.

### 14. Bug de processo: sessão local sem commit/push corrompeu o parâmetro SSM da decisão 10

Todo o código desta sessão foi escrito localmente sem commit/push antes de pedir ao operador para aplicar o grant `ManagePlatformIrsaRoles` via CloudShell. O CloudShell clona do GitHub, então via só a `main` antiga — sem o `ssm.tf` da decisão 10. Como o state remoto (S3, compartilhado) já tinha o parâmetro (criado por uma sessão local anterior), o `terraform plan` do CloudShell viu um recurso "no state mas não no código" e propôs destruí-lo; o operador, seguindo o fluxo normal de revisão de plano, aplicou. Resultado: o parâmetro SSM (e a chave privada que ele guardava) foi apagado sem que ninguém tivesse feito algo "errado" isoladamente — cada lado seguiu o processo corretamente com uma visão desatualizada do outro lado.

**Corrigido:** commit + push da branch antes de qualquer operação Terraform pedida a uma sessão diferente (CloudShell, outro operador) contra o mesmo backend remoto. **Lição de processo, não de código:** duas sessões Terraform contra o mesmo state remoto precisam do mesmo código local antes de qualquer `plan`/`apply` em qualquer uma delas — nunca presumir que "o state já tem a resposta certa" substitui sincronizar o código primeiro.

### 15. `terraform destroy` deixa recursos AWS órfãos quando o `aws-load-balancer-controller` está envolvido

As 3 Applications de add-ons e a Application `app`/`platform` (declaradas via `helm_release.argocd_apps`, decisões 6-7) não têm o finalizer `resources-finalizer.argocd.argoproj.io`. Ao destruir `envs/lab`, a ordem de destruição do Terraform (node group antes de qualquer coisa que dependa dele ainda estar de pé) mata o pod do `aws-load-balancer-controller` **antes** de qualquer Ingress ser removido — o controller nunca tem a chance de deletar a ALB que ele mesmo provisionou. Três consequências em cadeia, todas descobertas só no `destroy` real desta sessão (nenhuma delas aparece num `plan -destroy`):

1. **ALB órfã na AWS**, com ENIs `in-use` nas subnets públicas, bloqueando `DeleteSubnet`/`DetachInternetGateway` (`DependencyViolation`). Corrigido via `aws elbv2 delete-load-balancer` manual.
2. **Namespace `argocd` preso em `Terminating`** por causa dos finalizers `elbv2.k8s.aws/resources` (no Ingress) e `group.ingress.k8s.aws/minitube` (no `TargetGroupBinding`) — só o controller (já morto) os removeria. Tentar remover os finalizers via `kubectl patch` falhava por sua vez no *admission webhook* do próprio LBC (`no endpoints available`, o pod do webhook também está morto). Corrigido deletando primeiro as `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration` `aws-load-balancer-webhook`, depois removendo os finalizers manualmente.
3. **Duas security groups criadas pelo LBC** (`k8s-<cluster>-<hash>`, `k8s-traffic-<cluster>-<hash>`) sobrevivendo ao cluster inteiro, bloqueando `DeleteVpc`. Corrigidas via `aws ec2 delete-security-group` (sem regras cruzadas entre si, seguras para apagar diretamente).

**Não corrigido no código desta sessão** — registrado como dívida técnica: nenhuma das três correções foi automatizada; todas exigiram intervenção manual via AWS CLI durante o `destroy`. Candidatos para uma sessão futura: (a) adotar o finalizer nas Applications que gerenciam recursos do LBC, aceitando que o `destroy` do Terraform passa a esperar o ArgoCD deletar os recursos primeiro (mais lento, porém automático); ou (b) um passo de pre-destroy no runbook/script que roda `kubectl delete ingress --all -A` e aguarda a ALB sumir antes de `terraform destroy` tocar no node group.

## Consequências

- `terraform/bootstrap-iam/main.tf` ganha a `Statement` `ManagePlatformIrsaRoles` (aplicado via CloudShell/root, antes de qualquer `apply` em `envs/lab`).
- `terraform/envs/lab/iam-platform.tf` (novo): 3 `aws_iam_role` + policies (LBC vendorizada de `terraform/envs/lab/policies/aws-load-balancer-controller-iam-policy.json`; external-dns e cert-manager inline, escopadas à zone_id).
- `terraform/envs/lab/dns-data.tf` (novo): `data "aws_route53_zone"`/`data "aws_acm_certificate"`, consumidos de `terraform/bootstrap/` — nunca via `terraform_remote_state` (mesmo motivo do ADR 006: módulos com ciclo de vida diferente não se acoplam via state).
- `terraform/envs/lab/cloudfront.tf` (novo): OAC, bucket policy, distribution (S3 default + `/api/*` → ALB), alias Route53.
- `terraform/envs/lab/argocd.tf`: `AppProject` ganha destino `argocd`; Application `platform` ganha `directory.exclude`; 3 novas Applications multi-source; `kubernetes_secret_v1.argocd_repo_credentials` passa a ler `data.aws_ssm_parameter` em vez de `var.argocd_repo_ssh_private_key` (removida).
- `terraform/bootstrap/ssm.tf` (novo): `aws_ssm_parameter.argocd_repo_ssh_private_key`, persistente — ver decisão 10.
- `terraform/envs/lab/values/argocd.yaml`: `configs.params."server.insecure" = true` (TLS termina na ALB).
- `gitops/platform/{aws-load-balancer-controller,external-dns,cert-manager}/values.yaml`, `cert-manager/cluster-issuer.yaml`, `argocd/ingress.yaml` (novos).
- `gitops/app/ingress.yaml` (novo) + `kustomization.yaml` atualizado.
- `terraform/envs/lab/scripts/validate-cloudfront-dns-tls.sh` + `docs/runbooks/validate/validate-cloudfront-dns-tls.md` (novos), seguindo o padrão de validação funcional pós-apply (`docs/engineering-standards.md` §11).
