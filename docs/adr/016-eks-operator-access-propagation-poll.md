# 016 — Poll ativo no lugar do `time_sleep` fixo para a propagação da access entry

## Status

Aceito

## Contexto

Um `terraform apply` de `envs/lab`, recriando o ambiente do zero para validar as correções dos ADRs 014/015, falhou logo depois do node group terminar:

```
kubernetes_namespace_v1.argocd: Creating...
kubernetes_namespace_v1.platform: Creating...
Error: Unauthorized
```

`terraform state list` confirmou que `module.eks.time_sleep.operator_access_propagation` já estava no state (ou seja, os 30s já tinham rodado e terminado com sucesso) quando o erro aconteceu logo em seguida — descartando a hipótese óbvia de "o sleep nem chegou a rodar".

**Causa raiz:** mesma corrida já documentada na decisão 2 do [ADR 009](009-eks-access-entries-and-api-edge-routing.md): `CreateAccessEntry`/`AssociateAccessPolicy` retornam sucesso da API da AWS em ~1s, mas o *authorizer* do control plane do EKS leva um tempo **variável** a mais para de fato reconhecer o novo principal — sem nenhum `describe`/wait exposto pela API da AWS para confirmar essa propagação. O ADR 009 escolheu 30s fixos para essa espera, uma estimativa ("alguns segundos a mais") sem amostragem real. Da mesma forma que o orçamento fixo do `wait_for_alb` (ADR 010) precisou de retune no ADR 014 desta mesma sessão, os 30s se provaram insuficientes desta vez — a mesma classe de bug: um valor fixo, arbitrário, para um atraso de propagação da AWS que não é constante. (O erro apareceu como `401 Unauthorized` em vez do `403 Forbidden` original do ADR 009 — variação plausível de qual camada da autenticação/autorização do EKS rejeita primeiro, mesma causa de fundo.)

## Decisão

Em vez de só aumentar o valor fixo (mesmo remédio de curto prazo já usado duas vezes nesta sessão para o `wait_for_alb`), `time_sleep.operator_access_propagation` foi **substituído** por `null_resource.wait_for_operator_access` (`terraform/modules/eks/main.tf`), cujo `provisioner "local-exec"` verifica de verdade que o acesso funciona antes de liberar os recursos seguintes: gera um kubeconfig efêmero via `aws eks update-kubeconfig` (nunca toca o kubeconfig padrão do operador) e faz `kubectl get namespace kube-system` em loop, com orçamento de 120s (intervalo de 5s) e log de progresso em `stderr` — mesmo padrão de poll-com-deadline-e-log já estabelecido em `null_resource.wait_for_alb` (ADR 014) e `null_resource.cleanup_stale_metrics_apiservice` (ADR 015).

**Por que poll em vez de só aumentar o número, desta vez:** os dois casos anteriores (ALB, APIService) esperam por um recurso externo cuja criação/remoção é binária e observável via `describe`/`get`. Este caso é o mesmo formato — "o acesso funciona ou não" é uma pergunta que dá para responder diretamente (`kubectl get namespace`), em vez de inferir por tempo decorrido. Não há motivo para este ser o único dos três "esperas" do projeto ainda resolvido por adivinhação de duração.

**Consequência prática:** `module.eks` ganhou `variable "aws_region"` (o `aws eks update-kubeconfig` do script precisa de `--region` explícito; os providers `aws`/`kubernetes`/`helm` já carregam a região via configuração do provider, mas uma chamada de CLI dentro de um `local-exec` não). O provider `hashicorp/time` foi removido de `terraform/modules/eks/versions.tf` e `terraform/envs/lab/versions.tf` (não sobra mais nenhum uso); `hashicorp/null` foi adicionado ao módulo `eks` (antes só declarado no root).

## Consequências

- `terraform/modules/eks/main.tf`: `time_sleep.operator_access_propagation` (30s fixo) → `null_resource.wait_for_operator_access` (poll de até 120s, log de progresso).
- `terraform/modules/eks/variables.tf`: nova `variable "aws_region"`.
- `terraform/modules/eks/versions.tf`: `time` removido, `null ~> 3.2` adicionado.
- `terraform/envs/lab/versions.tf`: `time` removido (não usado em mais nenhum lugar do root).
- `terraform/envs/lab/eks.tf`: `module "eks"` passa `aws_region = var.aws_region`.
- Nenhuma mudança nos consumidores (`kubernetes_namespace_v1.argocd`/`.platform` continuam com `depends_on = [module.eks]`) — o endereço interno do recurso muda, a garantia de ordenação que o root module herda não.
- Validado nesta sessão via `terraform plan` contra o ambiente real, parcialmente aplicado (parado exatamente neste ponto): plano mostrou exatamente o esperado — 1 recurso destruído (`time_sleep` antigo, fora da configuração) e os 14 recursos restantes do ambiente a criar, sem nenhuma mudança fora do previsto. Validação funcional completa (o poll realmente evita o `Unauthorized` de ponta a ponta) fica para o próximo `apply` do operador.
- 3º orçamento fixo do projeto revisado na mesma sessão (`wait_for_alb`, `cleanup_stale_metrics_apiservice` por extensão do mesmo padrão, agora este) — se um quarto aparecer, vale considerar se existe um padrão geral a extrair (ex.: um módulo/helper reutilizável de "poll com deadline e log"), em vez de continuar duplicando o mesmo shape de script em cada `null_resource`.
