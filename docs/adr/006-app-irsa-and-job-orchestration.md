# 006 — IRSA da app, orquestração via Job e registro de imagens

## Status

Aceito

## Contexto

A Fase 2 introduz o primeiro workload real do projeto: uma API (FastAPI) que recebe upload de vídeo e dispara a transcodificação (FFmpeg → HLS) como um Job no EKS efêmero. Isso levanta três decisões novas: como a app acessa o S3 com segurança (IRSA), como a transcodificação é orquestrada, e onde vivem as imagens de container — nenhuma coberta pelos ADRs 001–005.

## Decisões

### 1. A IRSA role da app vive em `terraform/envs/lab/`, não em `terraform/bootstrap-iam/`

A trust policy de uma role IRSA referencia o ARN e a URL do OIDC provider do cluster (`aws_iam_openid_connect_provider.lab`, criado em `envs/lab/eks.tf` desde a Fase 1/ADR 004). Esse provider é recriado a cada sessão junto com o cluster — logo, qualquer role que confie nele também precisaria ser recriada/atualizada a cada sessão. Colocar a role em `bootstrap-iam` (padrão usado para as roles do cluster/node no ADR 004) exigiria reabrir CloudShell toda vez que o cluster fosse recriado, só para atualizar uma trust policy — a mesma fricção operacional que o ADR 002 já havia descartado.

A role (`minitube-app-irsa-role`) vive então em `envs/lab`, junto do OIDC provider, dentro do mesmo ciclo `apply`/`destroy`. Isso exige uma concessão pontual — feita uma única vez, via CloudShell — ao permission set do operador diário: uma nova `Statement` (`ManageAppIrsaRoles`) na policy inline já existente (`operator_pass_roles`, `terraform/bootstrap-iam/main.tf`), liberando `iam:CreateRole`/`DeleteRole`/`PutRolePolicy`/`DeleteRolePolicy`/`GetRole`/`GetRolePolicy`/`ListRolePolicies`/`TagRole`/`UntagRole`, **escopada por prefixo de nome** (`arn:aws:iam::<account>:role/minitube-app-*`), não por ARN específico (a role ainda não existe no momento em que a permissão é concedida). Depois dessa única concessão, o ciclo completo de `envs/lab` — incluindo a IRSA role — volta a ser operável 100% pelo operador via SSO, sem CloudShell.

### 2. Uma única role IRSA compartilhada por API e transcoder

A API só grava em `raw/`; o transcoder lê `raw/` e grava em `hls/` — mesmo bucket, mesma forma de policy. Duas roles quase idênticas não trariam isolamento real adicional neste estágio. A trust policy aceita os dois service accounts (`system:serviceaccount:minitube-app:api` e `:transcoder`) via `StringLike` na condition do `sub`.

### 3. Orquestração via Job Kubernetes dinâmico, criado pela API

A API cria um `batch/v1 Job` por vídeo recebido (`kubernetes` client Python, in-cluster config), em vez de um worker de fila (SQS, RabbitMQ) consumindo continuamente. Para "um vídeo de teste transcodificado" — o critério de conclusão desta fase — um Job por upload é a orquestração mais simples que resolve o problema. Fila/worker fica para quando o projeto precisar de retry robusto e paralelismo de verdade sob carga (Fase 6).

### 4. Repositórios ECR vivem em `terraform/bootstrap/`, não em `bootstrap-iam`

ECR não é bloqueado por `PowerUserAccess` — só IAM/Organizations são. Os dois repositórios (`minitube-api`, `minitube-transcoder`) são aplicáveis pelo operador diário via SSO, sem CloudShell, e persistem entre sessões (rebuildar imagens a cada teste seria desperdício). `image_tag_mutability = "IMMUTABLE"` reforça a convenção do projeto de nunca usar `latest`.

### 5. `kubectl apply -k gitops/app/` manual nesta fase

Os manifests já vivem em `gitops/app/` (Kustomize), prontos para o ArgoCD assumir na Fase 3, mas são aplicados manualmente por enquanto — mesma exceção temporária já usada nos smoke tests de VPC/EKS da Fase 1. Nenhum `kubectl apply` continuará manual além da Fase 3.

### Alternativas consideradas

- **IRSA role em `bootstrap-iam` + `terraform_remote_state`:** descartada — a trust policy fica presa ao ARN do OIDC provider, que muda a cada recriação do cluster; exigiria CloudShell a cada sessão de teste.
- **Reusar a role do node group (`eks_node`) para acesso S3, sem IRSA:** descartada — todo pod no node herdaria acesso ao bucket de vídeo, violando o menor privilégio já recomendado em `docs/engineering-standards.md` §8. Ficaria mais simples agora, mas a Fase 4 já vai trazer outros add-ons (aws-load-balancer-controller, external-dns, cert-manager) que precisam de roles IRSA próprias — melhor estabelecer o padrão correto já no primeiro workload.
- **Fila de mensagens (SQS) desde já:** descartada por escopo — YAGNI até a Fase 6, quando testes de carga de fato pressionarem a orquestração de múltiplos vídeos simultâneos.

## Consequências

- `terraform/bootstrap-iam/main.tf` ganha a `Statement` `ManageAppIrsaRoles` — qualquer role futura com prefixo `minitube-app-*` pode ser gerenciada por `envs/lab` sem tocar `bootstrap-iam` de novo.
- `terraform/envs/lab/` ganha `s3.tf` (bucket de vídeo) e `iam-app.tf` (role + policy IRSA), e destrói os dois junto com o resto a cada `terraform destroy` — nenhuma infraestrutura de app fica de pé fora do ciclo efêmero.
- `terraform/bootstrap/` ganha `ecr.tf` — os dois repositórios e as imagens neles persistem entre sessões.
- A validação funcional pós-apply ganha `terraform/envs/lab/scripts/validate-transcoding.sh` e o runbook [`docs/runbooks/validate-transcoding.md`](../runbooks/validate-transcoding.md).
- `kubectl apply -k gitops/app/` é uma exceção temporária ao princípio de GitOps (`docs/engineering-standards.md` §5) — deve deixar de ser necessária assim que o ArgoCD for instalado na Fase 3.
