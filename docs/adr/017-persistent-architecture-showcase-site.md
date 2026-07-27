# 017 — Página de arquitetura persistente (`system-design.<domínio>`)

## Status

Aceito

## Contexto

`docs/architecture.md` já existia como "material-base para divulgação" (ver `docs/showcase-urls.md`), pensado desde a Fase 4 para virar conteúdo de portfólio/LinkedIn ao final do projeto (decisão de fundo registrada no [ADR 007](007-argocd-gitops-bootstrap.md)). O plano original era só uma versão HTML mais rica visualmente desses diagramas, para anexar a um post.

Nesta sessão o operador propôs ir além: hospedar essa página **persistentemente**, num subdomínio próprio (`system-design.minitube.projetodevops.com.br`), para que a arquitetura fique navegável mesmo com `envs/lab` destruído — o estado normal do projeto entre sessões (princípio 1 do `CLAUDE.md`). Ou seja, uma vitrine que sobrevive exatamente quando o restante do sistema não está de pé para ser mostrado ao vivo.

## Decisões

### 1. Recurso novo em `terraform/bootstrap/`, não em `envs/lab/`

`terraform/bootstrap/` já é o lugar dos recursos de custo baixo e fixo que sobrevivem ao ciclo efêmero — bucket de state, repositórios ECR, hosted zone Route 53, certificado ACM wildcard, parâmetro SSM da deploy key ([ADR 001](001-terraform-state-backend.md), [008](008-cloudfront-dns-tls.md)). Uma página que precisa ficar no ar independente de `envs/lab` pertence à mesma categoria — não é uma exceção nova ao princípio de infraestrutura efêmera, é mais um membro dele.

### 2. Mesmo padrão S3 + OAC + CloudFront já validado, reaproveitado dentro do mesmo state

`terraform/bootstrap/architecture-site.tf` replica o shape de `envs/lab/cloudfront.tf` (origin `s3-video`: bucket privado, sem acesso público direto, `Origin Access Control`, policy escopada por `source-arn` da distribuição) — já em produção, sem reinventar. Única diferença real: como o bucket, a distribuição e o certificado wildcard agora vivem **no mesmo state**, o `viewer_certificate` referencia `aws_acm_certificate_validation.wildcard.certificate_arn` diretamente, sem precisar de um `data source` cross-module como `envs/lab` precisa.

**Alternativa descartada:** GitHub Pages (ou qualquer hospedagem externa gratuita). Rejeitada porque a base inteira necessária — hosted zone, certificado wildcard, o próprio padrão CloudFront+S3+OAC — já existe, já está testada em produção e já é código deste repositório; introduzir uma plataforma de hospedagem nova só para esta página adicionaria uma dependência externa sem necessidade, contra o objetivo didático do projeto (aprender construindo, não terceirizar a parte que já se sabe fazer).

### 3. Conteúdo fora do Terraform

O HTML/CSS/JS (`site/architecture/index.html`) é um arquivo estático versionado no repositório, **não** um `aws_s3_object` gerenciado pelo Terraform — sincronizado para o bucket por `terraform/bootstrap/scripts/deploy-architecture-site.sh` (`aws s3 sync` + invalidação do CloudFront), rodado manualmente quando o conteúdo muda. Mantém o `apply` de `bootstrap/` (recurso de infraestrutura, tocado raramente) desacoplado de ajustes de conteúdo/design (esperados com mais frequência durante a fase de divulgação).

### 4. Página auto-contida, sem dependência de CDN externo

`site/architecture/index.html` é um único arquivo com CSS/JS inline, sem `<script src>`/`<link>` para recursos externos (nenhuma fonte web, nenhuma biblioteca de gráficos) — os 4 diagramas de `docs/architecture.md` foram redesenhados como componentes HTML/CSS próprios (não a renderização padrão do Mermaid), estilizados para o tema visual da página em vez de herdar a paleta genérica do Mermaid. Objetivo: robustez e velocidade de carregamento para uma página pública que qualquer visitante de LinkedIn pode abrir a qualquer momento, sem depender da disponibilidade de terceiros.

**Tema único (escuro), deliberado:** a página assume o conceito visual de uma transmissão de jogo à noite, sob refletores — um tema claro descaracterizaria a própria ideia central, não só a paleta. Documentado como escolha consciente no próprio arquivo (comentário no `<style>`), não uma lacuna de acessibilidade não tratada.

## Consequências

- `terraform/bootstrap/architecture-site.tf` (novo): `aws_s3_bucket`, `aws_s3_bucket_public_access_block`, `aws_s3_bucket_server_side_encryption_configuration`, `aws_cloudfront_origin_access_control`, `aws_s3_bucket_policy`, `aws_cloudfront_distribution`, `aws_route53_record` — todos com sufixo/nome `architecture_site`.
- `terraform/bootstrap/outputs.tf`: `architecture_site_url`, `architecture_site_bucket_name`, `architecture_site_cloudfront_distribution_id`.
- `terraform/bootstrap/scripts/deploy-architecture-site.sh` (novo): sincroniza `site/architecture/` para o bucket e invalida o cache, lendo bucket/distribuição via `terraform output` (nenhum valor mágico).
- `site/architecture/index.html` (novo diretório `site/` na raiz): página única, conteúdo derivado de `docs/architecture.md`/`docs/000-motivation.md`, sem cópia 1:1 do Markdown.
- `docs/showcase-urls.md`: nova seção listando esta URL como a única que independe de `envs/lab` estar de pé.
- `CLAUDE.md` ("Estado atual"): recurso adicionado à lista de infraestrutura persistente entre sessões.
- **Custo estimado:** próximo de zero — S3 (poucos KB de HTML/CSS/JS) e CloudFront cobrados só por request/transferência; tráfego esperado de portfólio (dezenas/centenas de acessos). Sem custo fixo novo além do que já existe em `terraform/bootstrap/`.
- **Pendência conhecida, fora do escopo desta decisão:** o repositório GitHub ainda é privado (item já registrado como próximo passo no `CLAUDE.md`/ADR 007) — a página linka para ele, mas o link só funciona para visitantes depois que o repositório for tornado público.
- Validação funcional real (HTTPS válido, conteúdo servido de verdade em `system-design.<domínio>`) depende do primeiro `apply` de `bootstrap/` + primeiro deploy do conteúdo — não executado nesta sessão de design/construção do código.
