# Runbook: teste de ondas k6 (Fase 6)

## O quê

`load/run-waves-from-ec2.sh` roda `load/k6/waves.js` — audiência subindo e descendo em ondas ("pré-jogo" → "1º tempo" → "intervalo" → "2º tempo" → "pico do gol" → "apito final"), ao longo de ~23 minutos. Diferente de `load/k6/baseline.js` (crescimento monotônico, já validado estável) e `load/k6/breakpoint.js` (rampa até quebrar, sem descida), este é o primeiro cenário que **desce** de propósito — o objetivo central é observar o HPA (`gitops/app/hpa.yaml`, `minReplicas: 2`/`maxReplicas: 6`) escalando **para baixo** depois de um pico, não só para cima.

O estágio "pico do gol" mira deliberadamente perto do teto real já encontrado em [`docs/runbooks/run-k6-breakpoint.md`](run-k6-breakpoint.md) (execução `PEAK_RATE=800`): `maxReplicas: 6` × `limits.cpu: 500m` = 3 cores agregados, ponto em que a latência sobe (fila) sem erros reais aparecerem. Cruzar esse ponto de propósito — e depois descer — é o que torna este um teste de **recuperação**, não só mais um breakpoint: a latência volta a cair e as réplicas voltam a `minReplicas: 2` depois que a onda passa, ou algo fica preso?

## Por quê

Nem o baseline nem o breakpoint testam scale-down. `docs/adr/012-hpa-cpu-autoscaling.md` valida o HPA escalando 2→3→5→6 sob carga sustentada crescente — nunca o caminho inverso, que é igualmente parte do comportamento esperado de um HPA em produção (economia de custo entre picos, não só absorção de pico).

## Como

```bash
AWS_PROFILE=cloudlab ./load/run-waves-from-ec2.sh
```

Escalar o pico deliberado entre execuções (sem editar código):

```bash
WAVE_PEAK_RATE=1000 AWS_PROFILE=cloudlab ./load/run-waves-from-ec2.sh
```

`WAVE_PEAK_RATE` (default `700` req/s) é o topo do estágio "pico do gol" — os demais estágios escalam como fração dele (`pré-jogo` 15%, `1º tempo` 35%, `intervalo` 5%, `2º tempo` 45%, `apito final` 3%). A duração total (~23 minutos) é fixa, independente do valor.

Roda de dentro da AWS via EC2 efêmera, mesmo padrão de `load/run-breakpoint-from-ec2.sh` (ver seção "Rodando o k6 de dentro da AWS" em `run-k6-breakpoint.md` — necessário para eliminar ruído de rede do cliente, especialmente relevante aqui já que o objetivo é medir a forma exata da curva de recuperação, não só um único número de pico). Pré-requisitos: os mesmos dos outros scripts (`aws`, `jq`, `terraform`, `kubectl`, `curl`, `ffmpeg` no PATH; `terraform apply` já rodou; ArgoCD sincronizado; `k6` instalado remotamente via SSM, não localmente).

## Como ler o resultado

Ao contrário do breakpoint, **este teste não deveria abortar** (`abortOnFail` não está setado em nenhum threshold) — o objetivo é observar a forma completa da curva, incluindo a degradação esperada no pico. Cruzar sempre com o Grafana/Prometheus na janela exata do teste:

- **Réplicas do HPA:** confirmar 2 → 3 → 5 → 6 subindo até o "pico do gol", depois **voltando a 2** depois do "apito final" (`kubectl -n minitube-app get hpa api` logo após o teste, ou o histórico em `kube_deployment_status_replicas{namespace="minitube-app",deployment="api"}` no Prometheus).
- **Latência (`http_req_duration{endpoint:api}`):** esperado subir durante o "pico do gol" (mesmo padrão do `PEAK_RATE=800` do breakpoint) e voltar a valores baixos (~50-190ms, faixa já observada nos outros testes) durante o "apito final" — se não voltar, é sinal de algo preso (réplicas não escalando para baixo, conexões penduradas).
- **Taxa de erro:** esperado ficar perto de 0% durante todo o teste, inclusive no pico — a saturação observada no breakpoint é de fila/latência, não de erro.
- **Vale do "intervalo":** confirmar que o HPA não escala para baixo cedo demais nem demora demais — comportamento normal do HPA tem uma janela de estabilização (`stabilizationWindowSeconds`, default do `autoscaling/v2` é 5 min para scale-down) que pode fazer o vale do intervalo (2-3 min) não ser longo o suficiente para uma descida completa antes do "2º tempo" subir de novo — isso é esperado, não um bug.

## Resultado da execução (`<preencher após rodar>`)

_Aguardando primeira execução real contra o cluster — calibrado com o teto real encontrado em [`docs/runbooks/run-k6-breakpoint.md`](run-k6-breakpoint.md) (`PEAK_RATE=800`, `maxReplicas: 6` como limite atual)._
