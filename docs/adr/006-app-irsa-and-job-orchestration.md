# 006 — IRSA da app, orquestração via Job e registro de imagens

## Status

Aceito

## Contexto

A Fase 2 introduz o primeiro workload real do projeto: uma API (FastAPI) que recebe upload de vídeo e dispara a transcodificação (FFmpeg → HLS) como um Job no EKS efêmero. Isso levanta três decisões novas: como a app acessa o S3 com segurança (IRSA), como a transcodificação é orquestrada, e onde vivem as imagens de container — nenhuma coberta pelos ADRs 001–005.

## Decisões

### 1. A IRSA role da app vive em `terraform/envs/lab/`, não em `terraform/bootstrap-iam/`

A trust policy de uma role IRSA referencia o ARN e a URL do OIDC provider do cluster (`aws_iam_openid_connect_provider.lab`, criado em `envs/lab/eks.tf` desde a Fase 1/ADR 004). Esse provider é recriado a cada sessão junto com o cluster — logo, qualquer role que confie nele também precisaria ser recriada/atualizada a cada sessão. Colocar a role em `bootstrap-iam` (padrão usado para as roles do cluster/node no ADR 004) exigiria reabrir CloudShell toda vez que o cluster fosse recriado, só para atualizar uma trust policy — a mesma fricção operacional que o ADR 002 já havia descartado.

A role (`minitube-app-irsa-role`) vive então em `envs/lab`, junto do OIDC provider, dentro do mesmo ciclo `apply`/`destroy`. Isso exige uma concessão pontual — feita uma única vez, via CloudShell — ao permission set do operador diário: uma nova `Statement` (`ManageAppIrsaRoles`) na policy inline já existente (`operator_pass_roles`, `terraform/bootstrap-iam/main.tf`), liberando `iam:CreateRole`/`DeleteRole`/`PutRolePolicy`/`DeleteRolePolicy`/`GetRole`/`GetRolePolicy`/`ListRolePolicies`/`ListAttachedRolePolicies`/`TagRole`/`UntagRole`, **escopada por prefixo de nome** (`arn:aws:iam::<account>:role/minitube-app-*`), não por ARN específico (a role ainda não existe no momento em que a permissão é concedida). Depois dessa única concessão, o ciclo completo de `envs/lab` — incluindo a IRSA role — volta a ser operável 100% pelo operador via SSO, sem CloudShell.

`iam:ListAttachedRolePolicies` só foi descoberta como necessária num segundo teste real: o *refresh* de um `aws_iam_role` sempre verifica policies gerenciadas anexadas, mesmo quando só existe uma inline (como aqui) — o mesmo padrão de lacuna do item 5 (OIDC provider), só que na própria role da app.

Um terceiro round, desta vez no `terraform destroy`: `iam:ListInstanceProfilesForRole` também precisou ser adicionada — o provider AWS verifica instance profiles anexados antes de deletar a role, mesmo que esta role nunca tenha tido um. Mesma classe de lacuna (uma checagem do provider que não é óbvia a partir do `assume_role_policy`/`aws_iam_role_policy` do recurso), só que exposta no ciclo de destruição em vez de no `plan`.

### 2. Uma única role IRSA compartilhada por API e transcoder

A API só grava em `raw/`; o transcoder lê `raw/` e grava em `hls/` — mesmo bucket, mesma forma de policy. Duas roles quase idênticas não trariam isolamento real adicional neste estágio. A trust policy aceita os dois service accounts (`system:serviceaccount:minitube-app:api` e `:transcoder`) via `StringLike` na condition do `sub`.

### 3. Orquestração via Job Kubernetes dinâmico, criado pela API

A API cria um `batch/v1 Job` por vídeo recebido (`kubernetes` client Python, in-cluster config), em vez de um worker de fila (SQS, RabbitMQ) consumindo continuamente. Para "um vídeo de teste transcodificado" — o critério de conclusão desta fase — um Job por upload é a orquestração mais simples que resolve o problema. Fila/worker fica para quando o projeto precisar de retry robusto e paralelismo de verdade sob carga (Fase 6).

### 4. Repositórios ECR vivem em `terraform/bootstrap/`, não em `bootstrap-iam`

ECR não é bloqueado por `PowerUserAccess` — só IAM/Organizations são. Os dois repositórios (`minitube-api`, `minitube-transcoder`) são aplicáveis pelo operador diário via SSO, sem CloudShell, e persistem entre sessões (rebuildar imagens a cada teste seria desperdício). `image_tag_mutability = "IMMUTABLE"` reforça a convenção do projeto de nunca usar `latest`.

### 5. Concessão adicional: leitura/gestão do OIDC provider pelo operador

Descoberta em teste real, não antecipada no desenho original: `aws_iam_openid_connect_provider.lab` existe em `envs/lab` desde a Fase 1, mas todo `plan`/`apply` que o tocou até então rodou via CloudShell/root (inclusive a validação do EKS). Na primeira vez que o operador diário rodou `terraform plan` em `envs/lab` contra um state onde esse recurso **já existia**, o *refresh* falhou com `AccessDenied` em `iam:GetOpenIDConnectProvider` — uma ação nunca concedida. `terraform plan` sempre atualiza (`refresh`) todo recurso já presente no state antes de calcular o diff, não só os que estão mudando; para um recurso IAM, isso exige uma permissão de leitura explícita, não coberta pela concessão do item 1 (que só cobre `iam:*Role*`, não `iam:*OpenIDConnectProvider*`).

Corrigido com uma nova `Statement` (`ManageEksOidcProvider`) na mesma policy inline, cobrindo `Create`/`Delete`/`Get`/`Tag`/`Untag`/`ListTags` para `OpenIDConnectProvider`. Como o ARN do provider embute um ID de cluster atribuído pela AWS (não previsível por nome, ao contrário da role da app), o escopo usa `Resource` por padrão de conta/região/serviço (`oidc-provider/oidc.eks.<region>.amazonaws.com/id/*`), não um ARN exato.

### 6. Access entry explícita para o operador ter acesso ao cluster via kubectl

Outra descoberta em teste real: `bootstrap_cluster_creator_admin_permissions = true` (ADR 004) só concede admin a quem de fato chamou `CreateCluster` — que, na Fase 1, foi a sessão CloudShell/root, não o `cloudlab-operator`. Ao tentar `kubectl apply` localmente pela primeira vez, o operador nem conseguia autenticar no cluster (a mensagem de erro do lado do servidor era genérica, "the server has asked for the client to provide credentials" — sintoma de a identidade não ser reconhecida como principal válido, não um erro de RBAC).

Corrigido com um `aws_eks_access_entry` + `aws_eks_access_policy_association` (`AmazonEKSClusterAdminPolicy`, escopo `cluster`) explícitos em `envs/lab/eks.tf`, apontando pra `var.operator_role_arn`. Como `eks:CreateAccessEntry`/`AssociateAccessPolicy` não são ações de IAM, `PowerUserAccess` já permite isso ao operador diário — sem CloudShell.

A primeira tentativa resolvia esse ARN dinamicamente via `data "aws_iam_session_context"` (a partir de `data.aws_caller_identity.current.arn`, que é o ARN de uma sessão assumida, com sufixo de nome de sessão que não bate com o ARN da role em si). Essa abordagem falhou: o próprio data source chama `iam:GetRole` na role gerenciada pelo SSO (`AWSReservedSSO_cloudlab-operator_...`) — uma leitura de IAM fora do prefixo `minitube-app-*` já liberado, e um recurso que este projeto nem gerencia via Terraform. Perseguir mais uma permissão pontual pra esse caso específico não valia a pena. Em vez disso, `var.operator_role_arn` guarda o ARN fixo (obtido uma única vez via `aws iam get-role`, CloudShell/root, só leitura) — mesmo padrão já usado para `operator_sso_username` em `bootstrap-iam`. Não exige nenhuma concessão de IAM nova; só muda se o permission set for recriado (evento raro, já documentado como exceção no runbook).

### 7. `kubectl apply -k gitops/app/` manual nesta fase

Os manifests já vivem em `gitops/app/` (Kustomize), prontos para o ArgoCD assumir na Fase 3, mas são aplicados manualmente por enquanto — mesma exceção temporária já usada nos smoke tests de VPC/EKS da Fase 1. Nenhum `kubectl apply` continuará manual além da Fase 3.

### Alternativas consideradas

- **IRSA role em `bootstrap-iam` + `terraform_remote_state`:** descartada — a trust policy fica presa ao ARN do OIDC provider, que muda a cada recriação do cluster; exigiria CloudShell a cada sessão de teste.
- **Reusar a role do node group (`eks_node`) para acesso S3, sem IRSA:** descartada — todo pod no node herdaria acesso ao bucket de vídeo, violando o menor privilégio já recomendado em `docs/engineering-standards.md` §8. Ficaria mais simples agora, mas a Fase 4 já vai trazer outros add-ons (aws-load-balancer-controller, external-dns, cert-manager) que precisam de roles IRSA próprias — melhor estabelecer o padrão correto já no primeiro workload.
- **Fila de mensagens (SQS) desde já:** descartada por escopo — YAGNI até a Fase 6, quando testes de carga de fato pressionarem a orquestração de múltiplos vídeos simultâneos.

## Consequências

- `terraform/bootstrap-iam/main.tf` ganha as `Statement`s `ManageAppIrsaRoles` e `ManageEksOidcProvider` — qualquer role futura com prefixo `minitube-app-*`, e o próprio OIDC provider do cluster, podem ser gerenciados por `envs/lab` sem tocar `bootstrap-iam` de novo. Essa segunda concessão fecha uma lacuna que existia desde a Fase 1 (o OIDC provider só havia sido testado via CloudShell) e só foi exposta ao rodar `envs/lab` pela primeira vez com o profile do operador diário depois que o recurso já existia no state.
- `terraform/envs/lab/eks.tf` ganha `aws_eks_access_entry.operator` + `aws_eks_access_policy_association.operator_admin` — o acesso `kubectl` ao cluster deixa de depender de quem o criou originalmente.
- `terraform/envs/lab/` ganha `s3.tf` (bucket de vídeo) e `iam-app.tf` (role + policy IRSA), e destrói os dois junto com o resto a cada `terraform destroy` — nenhuma infraestrutura de app fica de pé fora do ciclo efêmero.
- `terraform/bootstrap/` ganha `ecr.tf` — os dois repositórios e as imagens neles persistem entre sessões.
- A validação funcional pós-apply ganha `terraform/envs/lab/scripts/validate-transcoding.sh` e o runbook [`docs/runbooks/validate-transcoding.md`](../runbooks/validate-transcoding.md).
- `kubectl apply -k gitops/app/` é uma exceção temporária ao princípio de GitOps (`docs/engineering-standards.md` §5) — deve deixar de ser necessária assim que o ArgoCD for instalado na Fase 3.

> **Atualização (Fase 3):** o `kubectl apply -k gitops/app/` manual deste item deixou de ser necessário — o ArgoCD assume a reconciliação completa de `gitops/app/` a partir desta fase. Decisão registrada em [ADR 007](007-argocd-gitops-bootstrap.md).
