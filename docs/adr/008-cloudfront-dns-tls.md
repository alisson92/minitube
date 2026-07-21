# 008 — CloudFront, DNS/TLS e add-ons de plataforma

## Status

Aceito

## Contexto

Critério de conclusão da Fase 4 (`CLAUDE.md`): `app.<domínio>` servindo vídeo via CDN com HTTPS válido. A fase foi dividida em 2 PRs por causa de uma dependência externa não instantânea: a delegação manual de NS records pelo usuário no registrador do domínio raiz. O primeiro PR (`feat/route53-zone-and-cert`, `terraform/bootstrap/dns.tf`) criou a hosted zone Route 53 (`minitube.projetodevops.com.br`) e o certificado ACM wildcard (`*.minitube.projetodevops.com.br`), ambos persistentes — confirmados nesta sessão, de forma independente, como delegados (`dig`) e `ISSUED` (`aws acm describe-certificate`), antes de qualquer código deste PR ser escrito. Este ADR cobre o segundo PR: CloudFront, as 3 IRSA roles de plataforma, os add-ons via GitOps e os Ingresses.

## Decisões

### 1. `app.<domínio>` = alias do CloudFront = critério de conclusão da fase

`terraform/envs/lab/cloudfront.tf` cria `aws_route53_record.app` como alias A record apontando para a distribution — via Terraform, não `external-dns`, já que o CloudFront é ele próprio um recurso Terraform (sem motivo para delegar essa descoberta a um controller in-cluster).

### 2. `argocd.<domínio>` vai direto à ALB, não via CloudFront

ArgoCD é ferramenta operacional interna — não se beneficia de cache de borda, e manter o CloudFront restrito a servir HLS por padrão + `/api/*` sob demanda mantém seu comportamento dinâmico mínimo. Roteado por `gitops/plataforma/argocd/ingress.yaml` + `external-dns` (a ALB é provisionada dinamicamente pelo controller, então só um controller in-cluster sabe seu endpoint atual a cada sessão — um `aws_route53_record` estático no Terraform não serviria aqui, ao contrário do registro do CloudFront).

### 3. Um único certificado ACM (us-east-1) serve CloudFront e ALB

Já previsto no comentário de `terraform/bootstrap/dns.tf` desde o PR #1. CloudFront exige `us-east-1` independente da região dos origins; a região deste projeto já é `us-east-1` por padrão.

### 4. IngressGroup compartilhado — uma única ALB para app e ArgoCD

`gitops/app/ingress.yaml` e `gitops/plataforma/argocd/ingress.yaml` usam `alb.ingress.kubernetes.io/group.name: minitube`, provisionando uma ALB só em vez de duas (custo: ~$0,0225/h fixo por ALB). Ambos fixam `alb.ingress.kubernetes.io/load-balancer-name: minitube-app` (idêntico nos dois) para dar à ALB um nome prévisível, em vez de depender das tags auto-geradas pelo controller.

### 5. `data "aws_lb"` por nome, não por tags — e a dependência circular que isso expõe

A ALB é provisionada dinamicamente pelo aws-load-balancer-controller a partir do Ingress, não pelo Terraform. `terraform/envs/lab/cloudfront.tf` precisa do seu DNS name para o origin dinâmico do CloudFront — resolvido via `data "aws_lb" { name = "minitube-app" }` (nome fixo, decisão 4), não via filtro de tags (cuja sintaxe exata do controller não vale a pena arriscar adivinhar).

Isso expõe uma dependência circular real: no primeiro `apply` de um ambiente novo, `helm_release.argocd_apps` (que dispara a reconciliação do Ingress → ALB) e a leitura de `data.aws_lb.app_shared` acontecem na mesma execução — a ALB pode não existir ainda quando o data source é lido, mesmo com `depends_on` garantindo a ordem correta dos recursos Terraform entre si (o `depends_on` não espera o ArgoCD/controller *dentro* do cluster terminarem de convergir). Mitigação: mesma classe de solução já usada no ADR 007 (decisão 8) para o bootstrap do próprio ArgoCD — um `apply` em duas etapas, documentado no runbook: se `data.aws_lb.app_shared` falhar por a ALB ainda não existir, aguardar ~1-2 min e reaplicar.

### 6. Entrega dos 3 add-ons via ArgoCD Application multi-source

Cada add-on (aws-load-balancer-controller, external-dns, cert-manager) é uma Application dedicada em `terraform/envs/lab/argocd.tf` (chart `argocd-apps`, mesmo mecanismo do ADR 007) com dois `sources`: o chart Helm oficial remoto + um `ref: values` apontando para este próprio repositório Git (`gitops/plataforma/<addon>/values.yaml`). Permite injetar o ARN da IRSA role correspondente (conhecido só pelo Terraform) via `helm.parameters`, sem copiar nada manualmente para o Git.

**Alternativas descartadas:**
- **Kustomize `helmCharts:` (HelmChartInflationGenerator):** incompatível com `directory.recurse = true`, já em uso pela Application `platform` — adotar exigiria trocar o tipo de source dessa Application inteira, sem ganho real sobre a opção escolhida.
- **`helm template` pré-renderizado e commitado:** quebra "Git como única fonte de verdade" a cada bump de versão de chart — o ArgoCD nunca saberia que o chart mudou, risco de drift silencioso entre o commitado e o chart real.

### 7. `gitops/plataforma/` ganha subdiretório por add-on; Application `platform` exclui `values.yaml`

Os `values.yaml` de cada add-on não são manifests Kubernetes válidos sozinhos — a Application `platform` (modo `directory`, recursivo) ganha `directory.exclude = "**/values.yaml"` para não tentar sincronizá-los como recursos soltos. O único manifest plano real que a Application `platform` continua sincronizando nesta fase é `cert-manager/cluster-issuer.yaml`.

### 8. `ClusterIssuer` funcional, mas sem consumidor público real nesta fase

`gitops/plataforma/cert-manager/cluster-issuer.yaml` (DNS-01 via Route53) prova que a IRSA role do cert-manager e o RBAC funcionam ponta a ponta (ClusterIssuer chega a `Ready`), mas nenhum `Certificate` é emitido por ele ainda — CloudFront e a ALB usam o certificado ACM já existente e validado (persistente, PR #1). YAGNI: emitir um certificado Let's Encrypt real exigiria expor um endpoint HTTP-01 publicamente ou reusar o mesmo desafio DNS-01 sem ganho sobre o certificado ACM já validado. `hostedZoneID` é hardcoded no manifest (zona persistente, ID estável entre sessões) — mesmo padrão de `var.operator_role_arn`.

### 9. Ingress do app catch-all, sem `host:`

`gitops/app/ingress.yaml` não declara `host:` — o roteamento por domínio já é resolvido pelo alias do CloudFront (decisão 1); um `host: app.<domínio>` no Ingress colidiria semanticamente com isso, já que o tráfego que chega à ALB via CloudFront não carrega mais o hostname original em `/api/*` do jeito que o Ingress esperaria sem uma origin request policy adequada (já coberta via `Managed-AllViewerExceptHostHeader`).

### 10. Deploy key SSH do ArgoCD passa a persistir via SSM Parameter Store, não mais via `TF_VAR` a cada sessão

O ADR 007 (decisão 4) previa a chave privada só em `TF_VAR_argocd_repo_ssh_private_key`, sem persistência — o que, na prática, exigia gerar um novo par e recadastrar a deploy key no GitHub em **toda** sessão que recriasse `envs/lab`, contrariando o objetivo do projeto de que recriar o ambiente do zero seja indolor (`CLAUDE.md`, princípio 1: "se doer, o código ainda não está bom"). Discutido com o operador ao encontrar esse atrito na prática.

Corrigido: `terraform/bootstrap/ssm.tf` (novo) cria `aws_ssm_parameter.argocd_repo_ssh_private_key` (`SecureString`), persistente como os demais recursos de `bootstrap/` (ECR, zona Route 53, certificado). `lifecycle.ignore_changes = [value]` garante que só o primeiro `apply` (com um `TF_VAR_argocd_repo_ssh_private_key` real) grava o valor — todo `apply` seguinte, mesmo com a variável no default vazio, nunca tenta sobrescrevê-lo. `terraform/envs/lab/argocd.tf` passa a ler o valor via `data "aws_ssm_parameter" { with_decryption = true }`, não mais via variável sensível própria — a variável `argocd_repo_ssh_private_key` foi removida de `envs/lab/variables.tf`.

SSM Parameter Store foi escolhido (em vez de Secrets Manager) por não ter custo relevante no tier `Standard`/`SecureString` com a KMS key gerenciada `aws/ssm`, e por não ser uma ação restrita pelo `PowerUserAccess` do operador diário (ao contrário de qualquer recurso IAM) — sem necessidade de nenhuma concessão nova em `bootstrap-iam`. A deploy key em si continua sendo a escolha certa (ADR 007, decisão 4); só o mecanismo de persistência da chave privada mudou.

**Consequência prática:** a chave privada antiga (par gerado na Fase 3) não existia mais em disco em nenhum lugar — a deploy key órfã correspondente no GitHub foi removida e substituída por um novo par nesta sessão, cuja privada foi gravada uma única vez no parâmetro SSM. A partir de agora, nenhuma sessão futura precisa gerar ou cadastrar uma nova deploy key.

### 11. Novo prefixo IAM `minitube-platform-*`

`terraform/bootstrap-iam/main.tf` ganha a `Statement` `ManagePlatformIrsaRoles`, mesma forma de `ManageAppIrsaRoles` (ADR 006), escopada a `arn:aws:iam::<account>:role/minitube-platform-*` — prefixo distinto do `minitube-app-*` para manter as duas concessões auditáveis independentemente, mesmo com ações idênticas.

## Consequências

- `terraform/bootstrap-iam/main.tf` ganha a `Statement` `ManagePlatformIrsaRoles` (aplicado via CloudShell/root, antes de qualquer `apply` em `envs/lab`).
- `terraform/envs/lab/iam-platform.tf` (novo): 3 `aws_iam_role` + policies (LBC vendorizada de `terraform/envs/lab/policies/aws-load-balancer-controller-iam-policy.json`; external-dns e cert-manager inline, escopadas à zone_id).
- `terraform/envs/lab/dns-data.tf` (novo): `data "aws_route53_zone"`/`data "aws_acm_certificate"`, consumidos de `terraform/bootstrap/` — nunca via `terraform_remote_state` (mesmo motivo do ADR 006: módulos com ciclo de vida diferente não se acoplam via state).
- `terraform/envs/lab/cloudfront.tf` (novo): OAC, bucket policy, distribution (S3 default + `/api/*` → ALB), alias Route53.
- `terraform/envs/lab/argocd.tf`: `AppProject` ganha destino `argocd`; Application `platform` ganha `directory.exclude`; 3 novas Applications multi-source; `kubernetes_secret_v1.argocd_repo_credentials` passa a ler `data.aws_ssm_parameter` em vez de `var.argocd_repo_ssh_private_key` (removida).
- `terraform/bootstrap/ssm.tf` (novo): `aws_ssm_parameter.argocd_repo_ssh_private_key`, persistente — ver decisão 10.
- `terraform/envs/lab/values/argocd.yaml`: `configs.params."server.insecure" = true` (TLS termina na ALB).
- `gitops/plataforma/{aws-load-balancer-controller,external-dns,cert-manager}/values.yaml`, `cert-manager/cluster-issuer.yaml`, `argocd/ingress.yaml` (novos).
- `gitops/app/ingress.yaml` (novo) + `kustomization.yaml` atualizado.
- `terraform/envs/lab/scripts/validate-cloudfront-dns-tls.sh` + `docs/runbooks/validate-cloudfront-dns-tls.md` (novos), seguindo o padrão de validação funcional pós-apply (`docs/engineering-standards.md` §11).
