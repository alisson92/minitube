# Fase 4 — Borda, DNS e TLS

> Retrospecto da fase, escrito ao final dela. Não repete o conteúdo de ADRs e runbooks — linka para eles. Serve como insumo para a documentação final do projeto (ver `CLAUDE.md`, seção "Estrutura do repositório").
>
> **Nota sobre este arquivo:** escrito em backfill (Fase 6), a partir da seção "Estado atual" do `CLAUDE.md` e dos ADRs 007-010 — a série de retrospectos parou em `003-gitops.md` e só foi retomada ao planejar o fechamento da Fase 6.

## Objetivo da fase

CloudFront na frente do S3 (segmentos HLS); Route 53 + `external-dns` + `cert-manager` com o domínio próprio do operador. Critério de conclusão (`CLAUDE.md`): *"`app.<domínio>` servindo vídeo via CDN com HTTPS válido"*.

## O que foi entregue

| Entregável | Onde vive | Persistente ou efêmero |
| --- | --- | --- |
| Hosted zone Route 53 (`minitube.projetodevops.com.br`) + certificado ACM wildcard | `terraform/bootstrap/dns.tf` | Persistente |
| Parâmetro SSM da deploy key do ArgoCD | `terraform/bootstrap/ssm.tf` | Persistente |
| CloudFront (S3 default + `/api/*` → ALB) | `terraform/envs/lab/cloudfront.tf` | Efêmero |
| 3 IRSA roles de plataforma (aws-load-balancer-controller, external-dns, cert-manager) | `terraform/envs/lab/iam-platform.tf` | Efêmero |
| Add-ons via ArgoCD Application multi-source | `gitops/plataforma/{aws-load-balancer-controller,external-dns,cert-manager}/` | Efêmero |
| Ingress compartilhado (`IngressGroup`) para `app` e `argocd.<domínio>` | `gitops/app/ingress.yaml`, `gitops/plataforma/argocd/ingress.yaml` | Efêmero |
| Grant IAM `ManagePlatformIrsaRoles` | `terraform/bootstrap-iam/main.tf` | Persistente |

## Decisões de arquitetura (ADRs)

- **[ADR 008](../adr/008-cloudfront-dns-tls.md)** — decisão central da fase. Cobre: alias do CloudFront via Terraform (não `external-dns`); `argocd.<domínio>` direto na ALB, sem CDN; um único certificado ACM (`us-east-1`) para CloudFront e ALB; `IngressGroup` compartilhado (uma ALB só); add-ons via Application multi-source (chart oficial + values do próprio repo); persistência da deploy key SSH via SSM Parameter Store (substitui o `TF_VAR` reexportado a cada sessão do ADR 007).
- **[ADR 009](../adr/009-eks-access-entries-and-api-edge-routing.md)** — bugs pré-existentes das Fases 1 e 4, só expostos ao testar `/api/*` através do CloudFront de ponta a ponta pela primeira vez: `bootstrap_cluster_creator_admin_permissions` desligado (acesso ao cluster 100% declarado pelo Terraform); `time_sleep` de 30s para a propagação real de access entries; rotas da API sob `/api` (decisão da aplicação, não da borda); origin do CloudFront apontando para um registro Route 53 próprio (não o DNS bruto da ALB, fora do SAN do certificado wildcard).
- **[ADR 010](../adr/010-lbc-orphan-cleanup-and-alb-wait.md)** — fechado só numa sessão seguinte (antes de iniciar a Fase 5 de fato), mas é dívida técnica originada nesta fase: `null_resource` com poll da ALB antes do `apply` prosseguir; `AppProject` em `helm_release` próprio, destruído por último; finalizer `resources-finalizer.argocd.argoproj.io` nas Applications `app`/`platform`; `depends_on` cobrindo o caminho de rede completo e as policies IAM do LBC/external-dns. Encerra definitivamente o órfão do LBC no `destroy` (ver "Bugs reais" abaixo).

## Bugs reais encontrados e corrigidos

Nenhum destes apareceu em `terraform plan`/`validate` — só na sincronização real do ArgoCD e em requisições públicas de verdade contra o domínio:

1. **`AppProject.sourceRepos` não liberava os repositórios Helm dos add-ons** — `InvalidSpecError`, corrigido adicionando os 3 URLs de chart.
2. **`AppProject.destinations` não liberava `kube-system`** — o cert-manager cria RBAC de leader-election lá por padrão do upstream.
3. **`aws-load-balancer-controller` não descobre o VPC ID sozinho** neste cluster (IMDS falha) — corrigido injetando `vpcId` via `helm.parameters`.
4. **Prioridade de regras da ALB compartilhada invertida (`group.order`)** — a regra catch-all do `app` tinha prioridade maior que a regra host-específica do ArgoCD; `argocd.<domínio>` respondia com o 404 da própria API.
5. **Colisão de access entry** — `bootstrap_cluster_creator_admin_permissions=true` cria automaticamente uma access entry para quem chama `CreateCluster`; colide com a explícita quando essa identidade é `cloudlab-operator`. Corrigido desligando a flag (ADR 009).
6. **Corrida de propagação de access entry** — efeito colateral do bug 5: a API do EKS retorna sucesso antes do *authorizer* aceitar de fato o novo principal. Corrigido com `time_sleep` de 30s.
7. **API pública em `/api/*` sempre 404** — CloudFront encaminha o path sem reescrita, mas a API só respondia rotas na raiz; nunca detectado porque a validação sempre usou `port-forward` direto no Service. Corrigido movendo as rotas para `APIRouter(prefix="/api")`, com `readinessProbe`/`healthcheck-path` ajustados junto.
8. **CloudFront 502 no origin da ALB** — o CloudFront valida o hostname do TLS contra o `domain_name` do origin, que apontava para o DNS bruto da ALB, fora do SAN do certificado wildcard. Corrigido com um alias Route 53 próprio (`alb-origin.<domínio>`), coberto pelo wildcard.
9. **`terraform import` do access entry falhando por um data source não relacionado** — `terraform import` avalia todos os data sources do módulo, incluindo `data.aws_lb.app_shared` (que não resolve numa VPC sem ALB ainda). Contornado movendo `cloudfront.tf` temporariamente para fora do diretório durante o `import`.
10. **Bug de processo: sessão local sem commit/push corrompeu o parâmetro SSM** da deploy key — uma sessão paralela em CloudShell, com checkout desatualizado, viu o parâmetro como "no state mas não no código" e o destruiu ao aplicar. Corrigido pelo hábito de commitar/enviar a branch antes de pedir qualquer operação Terraform a outro ambiente contra o mesmo backend.
11. **`terraform destroy` deixa recursos AWS órfãos com o `aws-load-balancer-controller` envolvido** — ALB e 2 security groups sobrevivem ao node group destruído (`DependencyViolation`); namespace `argocd` preso em `Terminating` por finalizers do LBC sem controller vivo para removê-los. Recuperado manualmente nesta fase (via `aws elbv2 delete-load-balancer` + `aws ec2 delete-security-group` + remoção manual de finalizers); **corrigido definitivamente só no ADR 010**, numa sessão seguinte, após reaparecer 2 vezes mais (ADR 009 decisões 5-6).

## Como validamos

[`docs/runbooks/validate-cloudfront-dns-tls.md`](../runbooks/validate-cloudfront-dns-tls.md) + `scripts/validate-cloudfront-dns-tls.sh`, 9 checagens — a prova central: playlist HLS real servida via `https://app.minitube.projetodevops.com.br`, com header `X-Cache` do CloudFront e cadeia TLS emitida pela Amazon. Revalidado depois do fechamento do ADR 009 com upload real end-to-end (`POST /api/videos`, transcodificação, `GET /hls/<id>/playlist.m3u8` via CDN, vídeo reproduzido no VLC) e, novamente, depois do ADR 010, com 4 ciclos completos `apply`→`destroy` do zero.

## Lições aprendidas

- **`data` sources que dependem de recursos provisionados fora do Terraform (ALB via controller in-cluster) expõem dependências circulares reais**, não capturáveis só por `depends_on` entre recursos Terraform — precisam de espera ativa (poll) ou reaplicação em duas etapas.
- **Validação funcional que usa atalho (`port-forward` direto no Service) pode mascarar bugs reais de roteamento de borda** — só testar através do caminho público completo (CloudFront → ALB → Service) expôs os bugs 7 e 8.
- **`terraform destroy` com controllers in-cluster que provisionam recursos AWS fora do Terraform (LBC) é uma classe de risco recorrente**, não um incidente isolado — motivou o ADR 010 e a prática de sempre confirmar limpeza via API AWS direta, não só `terraform state list`.

## Estado final da fase

- Critério de conclusão cumprido: `app.minitube.projetodevops.com.br` serve vídeo via CDN com HTTPS válido.
- `terraform/bootstrap/` ganhou a hosted zone, o certificado ACM wildcard e o parâmetro SSM (persistentes); `terraform/bootstrap-iam/` ganhou o grant `ManagePlatformIrsaRoles`. `terraform/envs/lab/` confirmado destruído ao final de cada sessão desta fase.
- PRs: #12 (`feat/route53-zone-and-cert`), #13 (`feat/cloudfront-dns-tls`), #14 (`fix/eks-access-entry-and-api-healthcheck`) — mais #17 (`fix/lbc-orphan-finalizer-and-alb-wait`), que fecha a dívida técnica do bug 11 numa sessão seguinte, antes do início efetivo da Fase 5.

## Próxima fase

[Fase 5 — Observabilidade](../../CLAUDE.md#fases-do-projeto): kube-prometheus-stack, Loki, dashboards; SLOs de latência e disponibilidade definidos antes dos testes de carga da Fase 6.
