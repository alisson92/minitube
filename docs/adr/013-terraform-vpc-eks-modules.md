# 013 — Extração de `terraform/modules/vpc` e `terraform/modules/eks`

## Status

Aceito

## Contexto

Com o roadmap de fases encerrado (Fase 6), esta sessão revisou a organização do repositório contra `docs/engineering-standards.md` e práticas de mercado, antes de tornar o repositório público para portfólio. Um dos achados: `terraform/envs/lab/` sempre foi um único root module monolítico — `vpc.tf` e `eks.tf` declaram os recursos diretamente, sem nenhum bloco `module {}` em lugar nenhum do repositório, apesar de o autor estar se preparando para a certificação Terraform Associate (`CLAUDE.md`, "Objetivos de aprendizado"), que cobra esse padrão diretamente, e de `docs/engineering-standards.md` (seção 6) já recomendar "módulos pequenos e coesos".

O momento é deliberado, não incidental: `terraform/envs/lab/` está destruído (princípio de infraestrutura efêmera, sempre respeitado entre sessões) — não existe state real para migrar. Refatorar recursos para dentro de um `module {}` muda o *resource address* de cada um (`aws_vpc.lab` vira `module.vpc.aws_vpc.this`, por exemplo); contra um ambiente vivo isso exigiria `terraform state mv` cuidadoso para não recriar tudo à toa. Contra um ambiente já destruído, o próximo `apply` simplesmente cria os recursos nos novos endereços — sem risco, sem migração de state, sem downtime a evitar. Dificilmente há um momento mais barato para fazer essa mudança do que agora.

## Decisões

### 1. Dois módulos, não um único `infra` genérico

`terraform/modules/vpc/` (VPC, subnets, IGW, NAT Gateway, route tables) e `terraform/modules/eks/` (cluster, node group spot, OIDC provider para IRSA, access entry do operador) — extraídos de `vpc.tf` e `eks.tf` respectivamente, mantendo a mesma divisão por domínio que o repositório já usava para arquivos. São os dois blocos de infraestrutura mais fundacionais e mais próximos de "genéricos o bastante para reaproveitar" (qualquer projeto EKS precisa de uma VPC e um cluster nesse formato); as IRSA roles de app/plataforma (`iam-app.tf`, `iam-platform.tf`) e o bootstrap do ArgoCD (`argocd.tf`) continuam no root module — são específicos deste projeto, sem valor didático adicional em virar módulo agora (YAGNI).

### 2. Módulos próprios, não o Registry (`terraform-aws-modules/vpc`, `terraform-aws-modules/eks`)

`CLAUDE.md` já registra a preferência geral do projeto: "prefira escrever módulos próprios a copiar módulos prontos quando o objetivo for didático" (princípio 5). Os módulos do Registry são a escolha certa para produtividade em produção real, mas escondem exatamente a mecânica (tags de subnet para auto-discovery do LBC, o único NAT Gateway como decisão de custo, `authentication_mode = "API"` vs. a ConfigMap legada) que este projeto existe para praticar de baixo para cima.

### 3. Convenção de nomes: `this` para o recurso singular de cada módulo

Segue a convenção comum em módulos Terraform da comunidade (`aws_vpc.this`, `aws_eks_cluster.this`) em vez do antigo `.lab` (um nome de ambiente, que não faz sentido dentro de um módulo reutilizável por múltiplos ambientes). O node group manteve `spot` (`aws_eks_node_group.spot`) por já ser descritivo por si só.

### 4. `time_sleep.operator_access_propagation` migrou para dentro de `module.eks`

Esse recurso (ADR 009, decisão 2 — espera a propagação da access entry no *authorizer* do EKS) dependia só de recursos que agora vivem dentro de `module.eks` (`aws_eks_access_entry.operator`, `aws_eks_access_policy_association.operator_admin`) e só era consumido, via `depends_on`, por recursos Kubernetes/Helm no root module. Movê-lo para dentro do módulo elimina uma dependência cruzada desnecessária: o root module agora só precisa de `depends_on = [module.eks]` para herdar a espera, sem saber que ela existe internamente.

### 5. `depends_on` no root module simplificado para nível de módulo

O `depends_on` mais crítico do repositório (`helm_release.argocd_apps`, Application `platform`, ver ADR 010 decisão 4) enumerava manualmente os 6 recursos de rede que garantem que o egress sobrevive até o LBC terminar de limpar a ALB compartilhada no `destroy`. Com esses 6 recursos agora dentro de `module.vpc`, `depends_on = [module.vpc]` expressa exatamente a mesma garantia (Terraform trata dependência em um módulo como dependência em todos os seus recursos) — e, diferente da lista manual, continua correta automaticamente se o módulo ganhar mais recursos de rede no futuro. Mesma simplificação aplicada aos dois outros `depends_on` que apontavam para recursos específicos do EKS (`helm_release.argocd` esperando o node group; `kubernetes_namespace_v1.argocd` esperando a access entry) — ambos viram `depends_on = [module.eks]`.

### 6. Outputs do módulo `eks` já entregam `oidc_provider_url` pronto

Antes, `local.oidc_provider_url = replace(aws_iam_openid_connect_provider.lab.url, "https://", "")` vivia duplicado como lógica no root module (`iam-app.tf`), consumido por `iam-app.tf` e `iam-platform.tf`. Como o módulo já expõe o ARN (`oidc_provider_arn`) para as trust policies de IRSA, faz sentido expor a URL já tratada (`oidc_provider_url`) também como output — uma única fonte de verdade para essa transformação, dentro do módulo que possui o recurso.

## Consequências

- Nenhuma mudança de comportamento: os mesmos recursos, com os mesmos argumentos, nos mesmos lugares da AWS — só o *resource address* no state muda.
- `docs/runbooks/validate/validate-argocd-gitops.md` (o único lugar que referenciava endereços de recurso individuais em um comando real, não em prosa histórica) precisou atualizar seu fallback de `-target` em duas etapas: os 3 `-target=aws_eks_cluster.lab`/`aws_eks_node_group.lab_spot`/`aws_iam_openid_connect_provider.lab` viraram um único `-target=module.eks`.
- ADRs anteriores (004, 007, 008, 009, 010, 011) que mencionam `aws_vpc.lab`, `aws_eks_cluster.lab` etc. **não foram reescritos** — são registros históricos de decisões tomadas contra o código como ele existia naquele momento; alterá-los agora misturaria a decisão original com uma refatoração posterior. Este ADR é o ponteiro para "onde esses recursos moraram depois".
- Próximo candidato natural, se o projeto crescer para múltiplos ambientes reais (hoje só existe `lab`): os outros arquivos de `envs/lab/` (`iam-app.tf`, `iam-platform.tf`, `cloudfront.tf`) ganhando seus próprios módulos — não feito agora por não haver um segundo ambiente que justifique a reutilização.

## Validação

`terraform fmt -recursive` e `terraform validate` limpos em `terraform/envs/lab/` e em cada módulo isoladamente (`terraform/modules/vpc/`, `terraform/modules/eks/`). Sem sessão AWS ativa nesta revisão (infraestrutura destruída por design), então um `terraform plan` real fica para o próximo `apply` do operador — que deve mostrar a criação líquida dos mesmos recursos de sempre, agora sob os novos endereços `module.vpc.*`/`module.eks.*`, sem nenhum recurso além desses.
