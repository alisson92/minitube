# Runbook — Validação funcional da transcodificação (API + transcoder)

> Estabelece o padrão de "validação funcional pós-apply" descrito em [`docs/engineering-standards.md`](../engineering-standards.md#11-validação-funcional-pós-apply). Ver também [`docs/adr/006-app-irsa-and-job-orchestration.md`](../adr/006-app-irsa-and-job-orchestration.md).

## Por que isso existe

`kubectl apply -k gitops/app/` sem erro e os pods `Running` provam que os manifests **existem com a configuração esperada** — não provam que um vídeo real consegue ser enviado, transcodificado e servido como HLS. A pergunta que importa: um upload real dispara um Job real, que roda o FFmpeg de verdade e grava segmentos legíveis no S3? Isso só se responde exercitando o pipeline ponta a ponta.

Este runbook documenta `terraform/envs/lab/scripts/validate-transcoding.sh`, que gera um vídeo sintético com FFmpeg (sem commitar binário no repo), envia via `POST /videos`, espera o Job terminar, e confirma a playlist + segmentos no S3.

## Pré-requisitos

### 1. Grant de IAM ao operador (uma única vez, via CloudShell)

A IRSA role da app precisa que o operador diário ganhe permissão para gerenciar roles com prefixo `minitube-app-*`, e também para ler/gerenciar o OIDC provider do cluster (`aws_iam_openid_connect_provider.lab`, existente desde a Fase 1, mas nunca antes planejado pelo profile do operador) — ver decisão em [ADR 006](../adr/006-app-irsa-and-job-orchestration.md). Sem isso, `terraform plan`/`apply` em `envs/lab` falha: ao tentar criar `aws_iam_role.app` (primeira execução) ou, em qualquer execução seguinte, ao fazer o *refresh* do OIDC provider já existente no state (`AccessDenied` em `iam:GetOpenIDConnectProvider`).

```bash
# Sessão root/CloudShell, uma única vez
cd terraform/bootstrap-iam
terraform plan     # revisar: 2 statements novas na inline policy do operador (ManageAppIrsaRoles, ManageEksOidcProvider)
terraform apply
```

### 2. Repositórios ECR (operador diário, sem CloudShell)

```bash
cd terraform/bootstrap
AWS_PROFILE=cloudlab terraform plan     # revisar: 2 aws_ecr_repository novos
AWS_PROFILE=cloudlab terraform apply
```

### 3. Build e push das imagens (manual — sem CI nesta fase)

```bash
account_id=$(aws sts get-caller-identity --profile cloudlab --query Account --output text)
aws ecr get-login-password --region us-east-1 --profile cloudlab | \
  docker login --username AWS --password-stdin "${account_id}.dkr.ecr.us-east-1.amazonaws.com"

docker build -t "${account_id}.dkr.ecr.us-east-1.amazonaws.com/minitube-api:v0.1.0" app/api
docker push "${account_id}.dkr.ecr.us-east-1.amazonaws.com/minitube-api:v0.1.0"

docker build -t "${account_id}.dkr.ecr.us-east-1.amazonaws.com/minitube-transcoder:v0.1.0" app/transcoder
docker push "${account_id}.dkr.ecr.us-east-1.amazonaws.com/minitube-transcoder:v0.1.0"
```

### 4. VPC + EKS + bucket S3 + IRSA role (operador diário, sem CloudShell)

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan     # revisar: VPC+EKS (se recriando) + bucket S3 + IRSA role + policy
AWS_PROFILE=cloudlab terraform apply
```

### 5. Deploy manual dos manifests

> ⚠️ Manual só nesta fase — o ArgoCD assume a reconciliação de `gitops/app/` na Fase 3. Ver ADR 006.

```bash
aws eks update-kubeconfig --region us-east-1 --name minitube-lab --profile cloudlab
kubectl apply -k gitops/app/
kubectl -n minitube-app wait deployment/api --for=condition=Available --timeout=120s
```

## Executar o teste

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab ./scripts/validate-transcoding.sh
```

Dependências no seu ambiente: `aws` CLI, `jq`, `terraform`, `kubectl`, `curl`, `ffmpeg`.

## Como funciona

- Gera um clipe sintético de 3s (`ffmpeg -f lavfi`) — sem depender de um arquivo de vídeo commitado no repo.
- Abre um `kubectl port-forward` para o Service da API (sem Ingress/ALB ainda — isso é Fase 4).
- `POST /videos` com o clipe; a API grava o bruto em `s3://<bucket>/raw/<video_id>.mp4` e cria um Job `transcode-<video_id>`.
- Faz *poll* em `GET /videos/{video_id}` até `succeeded`/`failed` (timeout de 300s).
- Confirma via `aws s3api head-object`/`aws s3 ls` que `hls/<video_id>/playlist.m3u8` e ao menos um segmento `.ts` existem.
- Se o Job falhar, imprime os logs do pod antes de sair (`kubectl logs job/transcode-<video_id>`), pra facilitar debug.
- **Cleanup garantido:** `trap cleanup EXIT` mata o `port-forward` e remove o vídeo temporário, mesmo em falha.

## Leitura esperada do output

```
PASS: API is reachable and healthy
PASS: transcode job succeeded (status=succeeded)
PASS: HLS playlist exists in S3 (hls/<video_id>/playlist.m3u8)
PASS: at least one HLS segment exists in S3 (found: 1)
=== All checks passed: a real video was uploaded, transcoded, and its HLS segments are readable in S3. ===
```

Código de saída `0` quando tudo passa, `1` se qualquer checagem falhar.

## Destruir tudo ao final do teste

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan -destroy   # revisar: VPC, EKS, bucket S3, IRSA role — tudo
AWS_PROFILE=cloudlab terraform destroy
```

`terraform/bootstrap/` (ECR) e `terraform/bootstrap-iam/` (roles, permission set, budget alert) **não** são destruídos — persistem entre sessões, sem custo relevante. As imagens no ECR também persistem, então a próxima sessão de teste não precisa rebuildar/repush a menos que o código tenha mudado.
