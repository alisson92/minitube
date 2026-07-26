# Runbook — do zero ao ambiente rodando (e de volta a zero)

> Ponto de entrada único: reúne, em ordem, a sequência completa de passos para rodar o MiniTube — desde uma conta AWS zerada até `app.<domínio>` servindo vídeo, e de volta a zero ao final. Não substitui os runbooks específicos (cada um continua sendo a fonte de verdade do seu próprio passo) — só os organiza numa ordem executável, com a fricção de cada etapa (o que é manual, o que exige uma sessão diferente, o que só roda uma vez) explícita.

## Qual parte você precisa

- **Retomando uma sessão de trabalho na conta AWS já usada neste projeto?** Vá direto para a "Parte 2 — ciclo de sessão", mais abaixo — a Parte 1 já foi feita e persiste entre sessões.
- **Bootstrapando uma conta AWS genuinamente nova** (replicando o projeto do zero, em outra conta)? Comece pela Parte 1.

## Visão geral

| Passo | O quê | Quem roda | Frequência |
| ----- | ----- | --------- | ---------- |
| 1.1 | Conta, MFA, Identity Center, usuário operador | Manual, console AWS | Uma vez por conta |
| 1.2 | Aplicar `terraform/bootstrap-iam/` | Root/CloudShell | Uma vez por conta¹ |
| 1.3 | Aplicar `terraform/bootstrap/` | Root/CloudShell (1ª vez) | Uma vez por conta¹ |
| 1.4 | Delegar o subdomínio no registrador | Manual, fora da AWS | Uma vez por domínio |
| 1.5 | Gerar a deploy key SSH do ArgoCD | `cloudlab-operator`, local | Uma vez por conta¹ |
| 1.6 | Configurar o profile SSO local | `cloudlab-operator`, local | Uma vez por conta/laptop |
| 2.1 | Login SSO | `cloudlab-operator`, local | Toda vez que a sessão expirar |
| 2.2 | Aplicar `terraform/envs/lab/` | `cloudlab-operator`, local | **Toda sessão** |
| 2.3 | Build + push das imagens | `cloudlab-operator`, local | Só se `app/` mudou |
| 2.4 | Validar cada subsistema | `cloudlab-operator`, local | **Toda sessão** |
| 2.5 | Usar o ambiente | `cloudlab-operator`, local | Conforme necessário |
| 2.6 | Destruir `terraform/envs/lab/` | `cloudlab-operator`, local | **Toda sessão**, ao final |

¹ Já aplicado e persistente para a conta usada neste projeto (`479213212405`) — reaplicar só é necessário se `bootstrap-iam/`/`bootstrap/` ganharem código novo (os passos 1.1/1.4 nunca se repetem; só o `terraform apply`).

---

## Parte 1 — bootstrap de uma conta AWS nova (uma vez por conta)

### 1.1 — Conta, MFA, Identity Center, usuário operador

Passo a passo completo (todos manuais, via console, sem Terraform) em [`docs/runbooks/bootstrap/aws-account-bootstrap.md`](bootstrap/aws-account-bootstrap.md), passos 1 a 5: criação da conta e MFA no root, abertura do CloudShell com cache de provider compartilhado, clone do repositório, ativação do IAM Identity Center e criação do usuário operador.

### 1.2 — Aplicar `bootstrap-iam` (CloudShell/root)

⚠️ **Só roda com sessão root/CloudShell.** Não é só o permission set do operador — hoje esse módulo já acumulou também as roles do EKS, a role de smoke test, o budget alert da conta e a policy inline com sete permissões diferentes concedidas ao operador ao longo do projeto. Detalhe completo de cada recurso no passo 6 de [`aws-account-bootstrap.md`](bootstrap/aws-account-bootstrap.md).

```bash
cd terraform/bootstrap-iam
terraform init
terraform plan
terraform apply
```

### 1.3 — Aplicar `bootstrap` (backend remoto, ECR, DNS)

Ainda na mesma sessão root/CloudShell (passo 7 de [`aws-account-bootstrap.md`](bootstrap/aws-account-bootstrap.md)) — o primeiro apply usa backend local, já que o bucket de state ainda não existe. Depois de criado, a migração para o backend S3 é feita à parte (ver [`bootstrap-remote-backend.md`](bootstrap/bootstrap-remote-backend.md) e [ADR 001](../adr/001-terraform-state-backend.md)).

```bash
cd ../bootstrap
terraform init
terraform plan
terraform apply
```

Cria, entre outros: o bucket de state, os dois repositórios ECR, a hosted zone Route 53 e o certificado ACM wildcard.

### 1.4 — Delegar o subdomínio no registrador (manual, fora da AWS)

```bash
terraform output route53_zone_name_servers
```

Cadastrar os 4 nameservers retornados como delegação NS no registrador do domínio raiz. **Não é instantâneo** — propagação de DNS pode levar de minutos a algumas horas; confirmar com `dig NS <domínio>` antes de seguir para a Parte 2.

### 1.5 — Gerar a deploy key SSH do ArgoCD (uma vez)

O ArgoCD precisa de credencial própria para clonar este repositório privado. Passos exatos (gerar o par de chaves, cadastrar a pública como deploy key read-only no GitHub, gravar a privada via um único `terraform apply` em `bootstrap/`) na seção "Pré-requisitos" de [`docs/runbooks/validate/validate-argocd-gitops.md`](validate/validate-argocd-gitops.md). Depois desse apply, a chave persiste no SSM Parameter Store e nunca mais precisa ser regenerada ou reexportada.

### 1.6 — Configurar o profile SSO local

Passo 8 de [`aws-account-bootstrap.md`](bootstrap/aws-account-bootstrap.md) — `~/.aws/config` com um `sso-session` dedicado, depois `aws sso login --profile cloudlab`.

**Ao final da Parte 1:** `terraform/bootstrap-iam/` e `terraform/bootstrap/` aplicados e persistentes; `terraform/envs/lab/` ainda não existe. Tudo daqui para frente é Parte 2, e se repete a cada sessão.

---

## Parte 2 — ciclo de sessão (toda vez que for usar o ambiente)

### 2.1 — Login SSO (se a sessão anterior expirou)

```bash
aws sso login --profile cloudlab
aws sts get-caller-identity --profile cloudlab
```

### 2.2 — Aplicar `terraform/envs/lab/`

```bash
cd terraform/envs/lab
terraform init -upgrade
AWS_PROFILE=cloudlab terraform plan
AWS_PROFILE=cloudlab terraform apply
```

Cria do zero: VPC, EKS (cluster + node group spot), bucket S3 de vídeo, IRSA roles, ArgoCD, CloudFront e todo o stack de observabilidade — reconciliados automaticamente pelo ArgoCD a partir do Git assim que o cluster sobe, sem nenhum `kubectl apply` manual.

⚠️ **Se o apply falhar em `helm_release.argocd` com erro de conexão logo após criar um cluster novo** (`connection refused`/`context deadline exceeded`): sintoma conhecido de o control plane ainda não estar pronto para os providers `kubernetes`/`helm` no mesmo apply em que nasceu — o cenário mais comum aqui, não a exceção, já que o cluster é recriado toda sessão. Fallback documentado na seção "Aplicar o ArgoCD e rodar o teste" de [`validate-argocd-gitops.md`](validate/validate-argocd-gitops.md): `terraform apply -target=module.eks` primeiro, depois o apply completo de novo.

### 2.3 — Build + push das imagens (só se o código de `app/` mudou)

Se `app/api/` e `app/transcoder/` não mudaram desde a última sessão, **pule este passo** — as imagens já estão publicadas no ECR (persistente) e `gitops/app/deployment.yaml` já referencia a tag certa.

Se mudou:

```bash
account_id=$(aws sts get-caller-identity --profile cloudlab --query Account --output text)
aws ecr get-login-password --region us-east-1 --profile cloudlab | \
  docker login --username AWS --password-stdin "${account_id}.dkr.ecr.us-east-1.amazonaws.com"

docker build -t "${account_id}.dkr.ecr.us-east-1.amazonaws.com/minitube-api:vX.Y.Z" app/api
docker push "${account_id}.dkr.ecr.us-east-1.amazonaws.com/minitube-api:vX.Y.Z"
# repetir para minitube-transcoder se app/transcoder/ também mudou
```

Depois, atualizar a tag em `gitops/app/deployment.yaml`, commitar e deixar o ArgoCD sincronizar — nunca `kubectl set image` manual (ver `docs/engineering-standards.md` §5).

### 2.4 — Validar cada subsistema

Rodar em ordem — cada um assume que o anterior já está de pé:

1. [`validate-vpc-network.md`](validate/validate-vpc-network.md) — egress real via NAT.
2. [`validate-eks-cluster.md`](validate/validate-eks-cluster.md) — control plane, nodes, pod real agendado.
3. [`validate-transcoding.md`](validate/validate-transcoding.md) — upload real → Job → FFmpeg → segmentos no S3.
4. [`validate-argocd-gitops.md`](validate/validate-argocd-gitops.md) — `selfHeal` reverte um drift manual sem `kubectl apply`.
5. [`validate-cloudfront-dns-tls.md`](validate/validate-cloudfront-dns-tls.md) — HLS real via CDN, HTTPS válido.
6. [`validate-observability.md`](validate/validate-observability.md) — PVCs, Prometheus, Grafana, Loki.

### 2.5 — Usar o ambiente

- **ArgoCD:** [`access-argocd-ui.md`](access-argocd-ui.md) — URL real + senha via `terraform output`.
- **Grafana:** `terraform output -raw grafana_admin_password`, em `grafana.<domínio>`.
- **Testes de carga (k6):** [`../../load/README.md`](../../load/README.md) para a visão geral dos 4 cenários, runbooks individuais em `docs/runbooks/load/`.
- **Experimentos de caos:** os 3 runbooks em `docs/runbooks/chaos/`, e [`incident-response.md`](incident-response.md) para o runbook de resposta a incidente que eles treinam.

### 2.6 — Destruir o ambiente (sempre, ao final da sessão)

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan -destroy
AWS_PROFILE=cloudlab terraform destroy
```

Depois, confirmar via API AWS direta — nunca confiar só em `terraform state list` — que não sobrou nada cobrável:

```bash
aws eks list-clusters --profile cloudlab --region us-east-1
aws ec2 describe-nat-gateways --profile cloudlab --region us-east-1 --filter Name=state,Values=available
aws elbv2 describe-load-balancers --profile cloudlab --region us-east-1
aws cloudfront list-distributions --profile cloudlab --query 'DistributionList.Items[?Enabled==`true`]'
```

Todas devem retornar vazio. Se o `destroy` travar com `DependencyViolation` no Internet Gateway/subnets — o sintoma clássico do órfão do `aws-load-balancer-controller` (ALB/security groups sobrevivendo ao node group) — a causa raiz já foi corrigida estruturalmente pelo [ADR 010](../adr/010-lbc-orphan-cleanup-and-alb-wait.md); se acontecer mesmo assim, o playbook de recuperação manual está na decisão 6 do [ADR 009](../adr/009-eks-access-entries-and-api-edge-routing.md).

`terraform/bootstrap-iam/` e `terraform/bootstrap/` **não são tocados** — ficam de pé entre sessões por design (ver "Estado atual" no [`CLAUDE.md`](../../CLAUDE.md)).
