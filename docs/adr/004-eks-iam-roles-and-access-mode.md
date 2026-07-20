# 004 — Roles IAM do EKS, modo de autenticação e node group gerenciado

## Status

Aceito

## Contexto

O próximo entregável da Fase 1 é o EKS com node group spot em `terraform/envs/lab/`, reaproveitando a VPC já validada. Isso exige decisões de arquitetura sobre onde ficam as roles IAM do cluster/node, como conceder acesso ao operador diário e que tipo de node group usar.

## Decisões

### 1. Roles do cluster e do node vivem em `terraform/bootstrap-iam/`, não em `terraform/envs/lab/`

Mesma razão dos ADRs 002/003: a policy `PowerUserAccess` do `cloudlab-operator` exclui **toda** ação de IAM, inclusive leituras (`iam:GetRole`, `iam:GetInstanceProfile`). As roles `minitube-eks-cluster-role` e `minitube-eks-node-role` só podem ser criadas via sessão root/CloudShell. `terraform/envs/lab/` as referencia por nome via `data "aws_iam_role"`, depois que a policy inline do permission set liberar `iam:GetRole`/`iam:PassRole` escopado a essas duas ARNs — o mesmo padrão já usado para a instance profile do smoke test de rede.

Consequência prática: um `destroy`/`apply` completo de `envs/lab` (critério de conclusão da Fase 1) nunca precisa reaplicar `bootstrap-iam` — as roles persistem fora do ciclo efêmero do ambiente.

### 2. Uma única inline policy, editada e não duplicada

A API do IAM Identity Center aceita **no máximo uma** inline policy por permission set. O recurso que já existia (`operator_pass_smoke_test_role`, liberando `iam:PassRole`/`iam:GetInstanceProfile` só para a role do smoke test de rede) foi renomeado para `operator_pass_roles` e passou a ter dois `Statement` (`Sid`s `PassSmokeTestRole` e `PassEksRoles`). Qualquer necessidade futura de `PassRole` para uma nova role (ex. IRSA de algum add-on) deve seguir o mesmo padrão: adicionar um `Statement` a este mesmo recurso, nunca criar um segundo `aws_ssoadmin_permission_set_inline_policy`.

### 3. `authentication_mode = "API"` em vez de `CONFIG_MAP`

O cluster usa **access entries** (modo `API`) com `bootstrap_cluster_creator_admin_permissions = true`, em vez do `aws-auth` ConfigMap legado. É o modo recomendado atualmente pela AWS para clusters novos, elimina a necessidade de editar um ConfigMap manualmente para conceder acesso, e o operador que aplica o Terraform já recebe permissões de admin no cluster automaticamente.

### 4. Node group gerenciado (`aws_eks_node_group`), não self-managed

Um managed node group cobre o Auto Scaling Group, a seleção de AMI otimizada e o dreno de nodes na atualização, sem exigir reimplementar isso em Terraform puro. Para um projeto de aprendizado, entender o EKS não exige reconstruir o que o node group gerenciado já resolve — o aprendizado de "como funciona por baixo" fica para quando fizer sentido (ex. ao investigar spot interruption handling).

### 5. `aws_iam_openid_connect_provider` (IRSA) criado já nesta fase

O provider OIDC é um recurso único, barato e idempotente por cluster. Criá-lo agora evita um retrofit acoplado à VPC/cluster quando o primeiro add-on que precisa de IRSA for implementado (Fase 4: aws-load-balancer-controller/external-dns/cert-manager; Fase 6: cluster-autoscaler ou Karpenter). Nenhuma IAM role de IRSA específica é criada agora — cada add-on cria a sua própria role só quando for implementado (YAGNI aplicado à role, não ao provider).

### Alternativas consideradas

- **Roles do EKS em `envs/lab`:** descartada pelo mesmo motivo do ADR 002 — `PowerUserAccess` bloqueia toda ação de IAM ao operador diário.
- **Segunda inline policy separada:** tecnicamente impossível — a API do Identity Center rejeita mais de uma inline policy por permission set.
- **`authentication_mode = "CONFIG_MAP"`:** descartada — depende do `aws-auth` ConfigMap legado, que a própria AWS está descontinuando como caminho recomendado.
- **Self-managed node group (ASG + launch template próprios):** descartada para esta fase — mais código para manter sem ganho de aprendizado proporcional; pode ser revisitada em ADR futuro se o projeto precisar de controle mais fino sobre o ciclo de vida dos nodes.
- **Adiar o OIDC provider para a Fase 4:** descartada — o custo de criar agora é desprezível, e adiar significaria tocar o módulo EKS de novo só para adicionar um recurso que não depende de nenhuma decisão ainda em aberto.

## Consequências

- `terraform/bootstrap-iam/main.tf` cresce com duas roles e uma policy inline unificada — qualquer novo `PassRole` futuro edita esse mesmo recurso.
- `terraform/envs/lab/` ganha `eks.tf`, novas variáveis (`eks_cluster_version`, `eks_node_instance_types`, `eks_node_desired_size`/`min_size`/`max_size`) e novos outputs (`eks_cluster_name`, `eks_cluster_endpoint`, `eks_cluster_certificate_authority_data`, `eks_oidc_provider_arn`).
- A validação funcional pós-apply (seção 11 do `engineering-standards.md`) ganha `scripts/validate-eks.sh` e o runbook [`docs/runbooks/validate-eks-cluster.md`](../runbooks/validate-eks-cluster.md).
- O endpoint público do cluster (`endpoint_public_access = true`) fica habilitado por simplicidade de acesso via kubectl no lab; se o projeto precisar restringir isso (ex. por `public_access_cidrs`), essa mudança merece seu próprio ADR quando o contexto de rede da Fase 4/5 estiver mais claro.

> **Atualização (Fase 2):** a suposição de que "o operador que aplica o Terraform já recebe permissões de admin automaticamente" (`bootstrap_cluster_creator_admin_permissions`) só vale para quem *criou* o cluster — na prática, isso foi o CloudShell/root na Fase 1, não o `cloudlab-operator`. Como o objetivo do projeto é que o operador diário use `envs/lab` sem depender de CloudShell, isso precisou de um `aws_eks_access_entry` explícito. Decisão registrada em [ADR 006](006-app-irsa-and-job-orchestration.md).
