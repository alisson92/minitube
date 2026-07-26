# Runbook — Validação funcional de CloudFront, DNS/TLS e add-ons de plataforma

> Estabelece o padrão de "validação funcional pós-apply" descrito em [`docs/engineering-standards.md`](../engineering-standards.md#11-validação-funcional-pós-apply). Ver também [`docs/adr/008-cloudfront-dns-tls.md`](../adr/008-cloudfront-dns-tls.md).

## Por que isso existe

Um `terraform apply` limpo criando a distribution do CloudFront e os `ClusterIssuer`/Ingress não prova que `app.<domínio>` de fato serve vídeo real via CDN com HTTPS válido — o critério de conclusão da Fase 4. Este runbook documenta `terraform/envs/lab/scripts/validate-cloudfront-dns-tls.sh`, cuja checagem central é uma requisição HTTPS real a um playlist HLS através do CloudFront, com cadeia TLS válida e header de cache presente.

## Pré-requisitos

### 0. Zona Route 53 delegada e certificado ACM emitido (PR #1 desta fase, `terraform/bootstrap/`)

```bash
cd terraform/bootstrap
AWS_PROFILE=cloudlab terraform apply    # se ainda não aplicado
dig NS minitube.projetodevops.com.br    # confirmar que resolve para nameservers awsdns-*
AWS_PROFILE=cloudlab aws acm describe-certificate \
  --region us-east-1 \
  --certificate-arn "$(terraform output -raw acm_certificate_arn)" \
  --query "Certificate.Status" --output text   # deve retornar ISSUED
```

### 1. Novo grant IAM em `bootstrap-iam` — via CloudShell/root

```bash
cd terraform/bootstrap-iam
terraform plan     # revisar: nova Statement "ManagePlatformIrsaRoles"
terraform apply
```

⚠️ Sem este `apply`, o `apply` de `envs/lab` falha com `AccessDenied` ao tentar criar as 3 IRSA roles de plataforma (`iam-platform.tf`).

### 2. Manifests/values de `gitops/` já commitados

O ArgoCD precisa achar `gitops/platform/{aws-load-balancer-controller,external-dns,cert-manager}/values.yaml`, `cert-manager/cluster-issuer.yaml`, `argocd/ingress.yaml` e `gitops/app/ingress.yaml` já na branch que `var.argocd_gitops_revision` apontar. Para testar antes do merge (mesmo padrão do ADR 007, decisão 5):

```bash
AWS_PROFILE=cloudlab terraform apply -var argocd_gitops_revision=feat/cloudfront-dns-tls
```

### 3. VPC + EKS + S3 + IRSA da app + ArgoCD (pré-requisitos das fases anteriores)

Ver [`docs/runbooks/validate-argocd-gitops.md`](./validate-argocd-gitops.md) e [`docs/runbooks/validate-transcoding.md`](./validate-transcoding.md).

## Aplicar e rodar o teste

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform init -upgrade
AWS_PROFILE=cloudlab terraform validate
AWS_PROFILE=cloudlab terraform plan     # revisar: 3 IRSA roles, CloudFront, 3 Applications novas, edits em argocd.tf
AWS_PROFILE=cloudlab terraform apply

AWS_PROFILE=cloudlab ./scripts/validate-cloudfront-dns-tls.sh
```

Dependências no seu ambiente: `aws` CLI, `jq`, `terraform`, `kubectl`, `curl`, `dig`, `openssl`, `ffmpeg`.

⚠️ **Se o `apply` falhar em `data.aws_lb.app_shared` ("no matching load balancer found")**: sintoma esperado num ambiente novo — a ALB só existe depois que o aws-load-balancer-controller reconcilia `gitops/app/ingress.yaml`, o que só acontece depois que `helm_release.argocd_apps` (mesma run) dispara a sincronização. Mesma classe do fallback em duas etapas já documentado no ADR 007 (decisão 8):

```bash
# Aguardar a ALB aparecer (1-2 min após o primeiro apply bem-sucedido do restante)
watch -n 10 'aws elbv2 describe-load-balancers --names minitube-app --profile cloudlab --region us-east-1 --query "LoadBalancers[0].State.Code" --output text'

# Reaplicar assim que o estado acima for "active"
AWS_PROFILE=cloudlab terraform apply
```

## Como funciona o script de validação

- **Kubeconfig efêmero**, mesmo padrão dos scripts anteriores.
- **Checagens executadas, em ordem:**
  1. `app.<domínio>` resolve via resolvedor público (até 5 min — propagação de DNS pode ter cache mesmo com o registro já correto no Route53).
  2. A distribution CloudFront atinge `Deployed` (até 10 min — é o passo mais lento de um `apply` novo).
  3. `ClusterIssuer letsencrypt-route53` atinge `Ready` — prova que a IRSA role e o RBAC do cert-manager funcionam ponta a ponta, mesmo sem nenhum `Certificate` real emitido ainda nesta fase.
  4. O `aws-load-balancer-controller` provisiona a ALB compartilhada (Ingress `api` ganha `.status.loadBalancer.ingress[0].hostname`).
  5. `argocd.<domínio>` resolve — prova que o `external-dns` está de fato criando registros a partir do Ingress do ArgoCD.
  6. A UI do ArgoCD responde via `https://argocd.<domínio>`, TLS válido, direto na ALB (sem CloudFront na frente).
  7. **Checagem central:** garante que existe HLS real no S3 (reaproveita o mesmo vídeo sintético de `validate-transcoding.sh` se `hls/` estiver vazio) e confirma que `https://app.<domínio>/hls/<video_id>/playlist.m3u8` responde `200`, carrega um header `X-Cache` do CloudFront (Hit ou Miss — qualquer um prova que passou pelo CDN) e apresenta uma cadeia TLS emitida pela Amazon (ACM).
- **Cleanup garantido:** `trap cleanup EXIT` mata o port-forward eventualmente aberto para o upload sintético e remove arquivos temporários — nenhum recurso de nuvem é criado só para este teste (ao contrário do smoke test de VPC/EC2), então não há necessidade de destruir nada além do kubeconfig efêmero.

## Leitura esperada do output

```
PASS: app.minitube.projetodevops.com.br resolves via a public resolver (up to 300s)
PASS: CloudFront distribution reaches Deployed (up to 600s)
PASS: ClusterIssuer letsencrypt-route53 reaches Ready (up to 180s)
PASS: aws-load-balancer-controller provisioned the shared ALB (up to 180s)
PASS: argocd.minitube.projetodevops.com.br resolves via a public resolver (up to 300s)
PASS: ArgoCD UI reachable via https://argocd.minitube.projetodevops.com.br with valid TLS
PASS: CloudFront serves the HLS playlist at https://app.minitube.projetodevops.com.br/hls/<video_id>/playlist.m3u8
PASS: response carries an X-Cache header from CloudFront (Hit or Miss)
PASS: TLS certificate chain for app.minitube.projetodevops.com.br is issued by Amazon (ACM)
=== All checks passed: app.minitube.projetodevops.com.br serves real HLS content via CloudFront over valid HTTPS, and argocd.minitube.projetodevops.com.br is reachable straight off the shared ALB. ===
```

Código de saída `0` quando tudo passa, `1` se qualquer checagem falhar. A primeira execução após um `apply` novo tende a ser a mais lenta (emissão/propagação do CloudFront, principalmente); reruns subsequentes no mesmo ambiente devem passar rapidamente em quase todas as checagens.

## Destruir tudo ao final do teste

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan -destroy   # revisar: remove CloudFront, IRSA de plataforma, Applications, junto com VPC/EKS/S3/IRSA(app)/ArgoCD — tudo
AWS_PROFILE=cloudlab terraform destroy
```

⚠️ **Risco conhecido (ADR 008, decisão 15): a ALB compartilhada pode ficar órfã.** As Applications do ArgoCD não têm o finalizer `resources-finalizer.argocd.argoproj.io`, então o `aws-load-balancer-controller` pode ser destruído (junto do node group) antes de conseguir deletar a ALB que provisionou — o `destroy` trava com `DependencyViolation` nas subnets/IGW. Se isso acontecer:

```bash
# 1. Deletar a ALB órfã manualmente
aws elbv2 delete-load-balancer --load-balancer-arn "$(aws elbv2 describe-load-balancers --names minitube-app --query 'LoadBalancers[0].LoadBalancerArn' --output text)"

# 2. Se o namespace argocd ficar preso em Terminating (finalizers do LBC no
#    Ingress/TargetGroupBinding, sem controller vivo para removê-los):
kubectl delete validatingwebhookconfigurations aws-load-balancer-webhook
kubectl delete mutatingwebhookconfigurations aws-load-balancer-webhook
kubectl patch ingress argocd-server -n argocd --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl patch targetgroupbindings.elbv2.k8s.aws -n argocd --all --type=merge -p '{"metadata":{"finalizers":[]}}'

# 3. Se a exclusão da VPC travar em DeleteVpc (security groups do LBC órfãs):
aws ec2 describe-security-groups --filters "Name=group-name,Values=k8s-*" --query "SecurityGroups[].GroupId" --output text
# para cada GroupId retornado:
aws ec2 delete-security-group --group-id <id>

# 4. Reaplicar o destroy normalmente
AWS_PROFILE=cloudlab terraform destroy
```

`terraform/bootstrap/` (state, ECR, **agora também a zona Route 53 e o certificado ACM**) e `terraform/bootstrap-iam/` (roles, permission set, budget alert, **incluindo o novo grant `ManagePlatformIrsaRoles`**) **não** são destruídos — persistem entre sessões. Confirmar que não sobrou nada cobrável:

```bash
aws eks list-clusters --profile cloudlab --region us-east-1
aws ec2 describe-vpcs --profile cloudlab --region us-east-1 --filters "Name=tag:Name,Values=minitube-lab"
aws ec2 describe-nat-gateways --profile cloudlab --region us-east-1 --filter "Name=state,Values=available"
aws cloudfront list-distributions --profile cloudlab --query "DistributionList.Items[].Id"
aws elbv2 describe-load-balancers --profile cloudlab --region us-east-1 --names minitube-app   # deve retornar erro "not found" após o destroy
```

A zona Route 53 e o certificado ACM (persistentes, `terraform/bootstrap/`) continuam de pé — isso é esperado e intencional, ver ADR 008.

## Segurança / rollback

Se o script for interrompido de forma anômala (`kill -9`) durante o upload sintético do vídeo, o port-forward pode ficar órfão:

```bash
pkill -f "port-forward svc/api" || true
```

Inofensivo mesmo se rodado sem necessidade. Nenhum outro estado precisa de reversão manual — este script não introduz drift proposital no cluster (ao contrário de `validate-argocd.sh`).
