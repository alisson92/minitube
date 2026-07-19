# Padrões de Engenharia

> **Documento reutilizável.** Define os padrões default de trabalho para qualquer projeto — versionamento, GitOps, IaC e segurança. É importado pelo `CLAUDE.md` do projeto via `@docs/engineering-standards.md`, de modo que o Claude Code carregue estes padrões automaticamente em toda sessão. Especificidades do projeto (arquitetura, fases, estado) **não** pertencem a este arquivo — vivem no `CLAUDE.md`.

## 1. Filosofia

- **A documentação oficial é a fonte primária.** Toda ferramenta ou framework utilizado é adotado e operado conforme sua **documentação oficial e seus guias de melhores práticas** — isso vale para o desenvolvimento (organização de branches, commits, layout da raiz do repositório) e para GitOps, Terraform, Kubernetes e CI/CD (ex.: Terraform Style Guide da HashiCorp, Best Practices do ArgoCD, Configuration Best Practices do Kubernetes, especificação do Conventional Commits). Em caso de dúvida sobre "o jeito certo", consulta-se a documentação atual da ferramenta antes de implementar.
- **Adoção da comunidade orienta a escolha.** Ao selecionar ferramentas, considerar as práticas atuais do mercado; no ecossistema cloud native, a referência de maturidade é a CNCF (preferir projetos *graduated* ou *incubating*; *sandbox* apenas com justificativa).
- **Desvios são exceção documentada.** Quando fugir do padrão de mercado fizer sentido, a decisão vira um ADR curto explicando o trade-off.
- **Convenção antes de improviso.** Se existe um padrão estabelecido (Conventional Commits, SemVer, labels recomendadas do Kubernetes), ele é adotado — não se inventa um equivalente próprio.

## 2. Idiomas

| Onde | Idioma |
| ---- | ------ |
| Commits, branches, código, identificadores, comentários de código | **Inglês** (padrão universal de desenvolvimento) |
| **Nomes de todos os diretórios e arquivos** do repositório | **Inglês**, sem exceção — ex.: `docs/000-motivation.md`, `docs/adr/`, `docs/runbooks/` |
| **Conteúdo** dos arquivos do diretório `docs/` e comunicação | **Português do Brasil** — para garantir plena compreensão durante o desenvolvimento |

> Por serem documentação, o `README.md` e o `CLAUDE.md` também têm conteúdo em português do Brasil. Isso é ajustável por projeto (ex.: README em inglês em um repositório de portfólio público).

> **Atenção — ambiguidade comum:** `description` de variáveis/outputs (Terraform), comentários dentro de manifests Kubernetes/Helm e qualquer comentário embutido em arquivo de código (`.tf`, `.yaml`, `.sh`, `.py` etc.) contam como **código**, não como "conteúdo de `docs/`" — mesmo que sejam texto explicativo em prosa. Ficam em **inglês**, sempre, independentemente de onde o arquivo mora no repositório. Só o conteúdo de arquivos dentro de `docs/` (e README/CLAUDE.md, pela exceção acima) fica em português.

> **Comentários de código:** curtos, diretos, uma linha sempre que possível. Só explicam o que não é óbvio pelo código (o "porquê", não o "o quê"). Sem parágrafos, sem repetir o que já está documentado em `docs/adr/` ou `docs/runbooks/` — linkar em vez de reexplicar.

## 3. Estratégia de branches

Adota-se **trunk-based development** com branches de curta duração — o modelo padrão da comunidade para fluxos de CI/CD e GitOps:

- `main` é a única branch de longa vida e deve estar **sempre íntegra e implantável**. Em GitOps, isso é inegociável: `main` é o que o cluster reconcilia.
- Todo trabalho nasce em uma branch curta a partir de `main`, integrada via Pull Request e apagada após o merge.
- Nomenclatura: `<tipo>/<descricao-kebab-case>`, com os mesmos tipos dos commits.
  - `feat/vpc-module`, `fix/nat-route-table`, `docs/adr-dns-zone`, `chore/pin-provider-versions`
- Branches vivem **dias, não semanas**. Trabalho grande é fatiado em entregas pequenas e integráveis.
- PRs pequenos e focados: um propósito por PR, com o `terraform plan` (ou diff equivalente) revisado na descrição quando aplicável.

## 4. Commits — Conventional Commits (em inglês)

Formato: `<type>(<scope>): <description>` — descrição no imperativo, minúscula, sem ponto final.

**Types:** `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`, `build`, `perf`, `revert`.

**Scopes:** refletem as áreas do repositório (ex.: `terraform`, `gitops`, `app`, `load`, `adr`).

```
feat(terraform): add vpc module with public and private subnets
fix(gitops): correct argocd sync policy for platform apps
docs(adr): record decision to persist route53 hosted zone
chore(terraform): pin aws provider to ~> 5.0
ci: add terraform fmt and validate checks
feat(app)!: change hls segment duration to 4s
```

- **Breaking changes:** `!` após o type/scope e rodapé `BREAKING CHANGE:` descrevendo o impacto.
- **Commits atômicos:** cada commit representa uma mudança lógica única que mantém o repositório íntegro.
- **Versionamento:** [SemVer](https://semver.org/) com tags anotadas (`v1.2.0`) para marcos/releases. Os types dos commits alimentam o versionamento (`fix` → patch, `feat` → minor, `!` → major).

## 5. GitOps

Seguem-se os quatro princípios do [OpenGitOps](https://opengitops.dev/) (CNCF):

1. **Declarativo:** todo o estado desejado do sistema é expresso declarativamente (manifests, não scripts imperativos).
2. **Versionado e imutável:** o estado desejado vive no Git — única fonte de verdade, com histórico completo.
3. **Aplicado automaticamente (pull):** agentes (ex.: ArgoCD) puxam o estado do Git; ninguém "empurra" mudanças para o cluster.
4. **Continuamente reconciliado:** o agente observa e corrige drift entre o estado real e o declarado.

Consequências práticas:

- **Proibido `kubectl apply`/`kubectl edit` manual** em qualquer recurso gerenciado pelo GitOps. Mudança de emergência feita à mão deve ser codificada e commitada imediatamente depois.
- **Rollback = `git revert`.** Nunca desfazer no cluster o que o Git ainda declara.
- Estrutura de manifests com **Kustomize** (base + overlays) ou Helm; um diretório por domínio (plataforma vs aplicação).

## 6. Infraestrutura como código (Terraform)

- **Estado remoto com lock** (ex.: S3 versionado), criado em um bootstrap separado. `*.tfstate` jamais no Git.
- **Fluxo obrigatório:** `terraform fmt` → `validate` → lint (`tflint`) → `plan` **revisado por humano** → `apply`. Nunca `apply -auto-approve` em recursos novos.
- **Comandos destrutivos sempre precedidos de dry-run:** `terraform plan -destroy` revisado antes de qualquer `destroy`.
- **Versões pinadas:** `required_version` do Terraform e constraints de providers (`~>`) explícitos.
- **Módulos pequenos e coesos**, com `variables` tipadas e com `description`, e `outputs` documentados. Preferir escrever módulos próprios quando o objetivo for aprendizado; usar módulos da comunidade (registry oficial) quando o objetivo for produtividade — decisão registrada em ADR se relevante.
- **Sem valores mágicos:** tudo parametrizado; nomes e tags de recursos padronizados (projeto, ambiente, gerenciado-por).

## 7. Kubernetes

- Recursos sempre com **requests/limits**, **liveness/readiness probes** e labels recomendadas (`app.kubernetes.io/name`, `app.kubernetes.io/part-of`, `app.kubernetes.io/managed-by`).
- Imagens com **tag imutável** (nunca `latest` em manifests versionados).
- Namespaces por domínio (plataforma vs aplicação); RBAC de menor privilégio.

## 8. Segurança

- **Nenhum segredo no Git** — nunca: credenciais, tokens, kubeconfig, `*.tfvars` sensíveis, estado do Terraform. `.gitignore` adequado é parte do primeiro commit do repositório.
- Segredos via mecanismos apropriados (variáveis de ambiente locais, secret managers, External Secrets/SOPS quando o projeto exigir).
- **Menor privilégio** em IAM e RBAC; na AWS, preferir IRSA a credenciais estáticas em pods.
- Scanners na esteira quando houver CI: `gitleaks` (segredos), `trivy` (imagens/IaC).

## 9. Documentação

- **README** responde: o que é, por que existe, como rodar em < 5 minutos.
- **ADRs** (`docs/adr/NNN-title.md` — nome do arquivo em inglês, conteúdo em PT-BR): curtos — contexto, decisão, consequências. Toda decisão de arquitetura relevante ou desvio de padrão gera um.
- **Runbooks** (`docs/runbooks/`): procedimentos operacionais passo a passo (subir, derrubar, responder a incidente).
- Documentação nasce **junto** com a mudança, no mesmo PR — não depois.

## 10. Automação e CI

- Validações automatizadas (fmt, lint, validate, testes) rodam **antes do merge** — o humano revisa intenção, a máquina revisa forma.
- Tudo que for executado mais de duas vezes manualmente é candidato a automação (script versionado ou pipeline).

## 11. Validação funcional pós-apply

`terraform apply` sem erro e um recurso com os atributos certos provam que ele **existe como esperado** — não provam que ele **funciona**. Todo entregável de infraestrutura relevante (rede, cluster, CDN, etc.) ganha um teste funcional que exercita o comportamento real, não só uma leitura de atributos via `describe-*`.

- O teste vive como script versionado (`scripts/validate-*.sh`, próximo ao módulo Terraform que ele valida) + um runbook em `docs/runbooks/validate-*.md` explicando o quê, por quê e como ler o resultado.
- Testes são **efêmeros e se autolimpam**: qualquer recurso criado só para o teste (instância, carga de trabalho) é destruído ao final, mesmo em caso de falha — scripts que criam recursos usam `trap` de cleanup (`EXIT`) sem exceção.
- O critério de conclusão de cada fase do projeto (ver `CLAUDE.md`) inclui a validação funcional correspondente, não só o `apply` limpo.
