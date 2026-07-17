# Motivação — por que este projeto existe

## A pergunta original

Tudo partiu de uma curiosidade durante a Copa do Mundo: **como a infraestrutura do YouTube consegue suportar um evento desse tamanho?** As transmissões dos jogos pela CazéTV bateram recordes de público simultâneo na plataforma — milhões de pessoas assistindo à mesma live, ao mesmo tempo, sem que nada caísse.

A pergunta que ficou foi: *o que acontece por baixo dos panos para isso funcionar?*

## A física do problema

Um stream em 1080p consome na ordem de 5 Mbps por espectador. Multiplicando por milhões de espectadores simultâneos, o tráfego agregado chega à casa dos **terabits por segundo** — nenhum servidor ou datacenter único é capaz de servir isso.

A resposta do YouTube (e de qualquer plataforma de streaming em escala) se apoia em alguns princípios:

1. **Vídeo é cacheável.** O mesmo segmento de 4 segundos é idêntico para todo mundo. Isso permite que a carga seja absorvida na borda (CDN), perto do espectador — no caso do Google, com servidores de cache instalados dentro dos próprios provedores de internet (Google Global Cache).
2. **Cada camada filtra tráfego.** A imensa maioria das requisições morre no cache da borda. Só os *cache misses* descem até o balanceamento global (anycast) e, por fim, até a origem.
3. **A origem escala horizontalmente.** Clusters de contêineres (Borg, o precursor do Kubernetes) com autoscaling, pipeline de transcodificação distribuído (cada vídeo vira dezenas de variantes de qualidade servidas em segmentos HLS/DASH) e práticas de SRE — SLOs, error budgets, resposta a incidentes.

## O que este projeto reproduz

O **MiniTube** é uma reprodução em miniatura dessa arquitetura, construída do zero, para praticar de forma integrada as disciplinas de DevOps e SRE do universo cloud native:

| Peça do mundo real (YouTube)          | Equivalente no MiniTube                       |
| ------------------------------------- | --------------------------------------------- |
| Google Global Cache / CDN             | CloudFront servindo segmentos HLS             |
| Armazenamento de vídeo                | S3 como origem dos segmentos                  |
| Borg (clusters de contêineres)        | EKS (Kubernetes gerenciado na AWS)            |
| Pipeline de transcodificação          | Job com FFmpeg gerando variantes HLS          |
| Deploys em escala                     | GitOps com ArgoCD                             |
| Monitoração e SRE                     | Prometheus, Grafana, Loki, SLOs               |
| A torcida chegando no gol             | Testes de carga com k6 em ondas               |

O objetivo final é **assistir ao "dia do jogo" pelos dashboards**: disparar ondas de tráfego simulando a torcida, ver a borda absorver a carga, o autoscaling reagir e os SLOs se comportarem — como um SRE de plantão.

## Por que a infraestrutura é efêmera

O projeto roda em cloud real (AWS) porque custo, rede e IAM fazem parte do aprendizado. Mas serviços gerenciados como o EKS cobram pelo control plane **mesmo com o cluster ocioso** — e é exatamente aí que o Terraform fecha o ciclo: ao final de cada bateria de testes, um `terraform destroy` derruba tudo e zera os custos.

Isso não é uma limitação — é o teste de qualidade do projeto: se destruir e recriar o ambiente dói, a infraestrutura como código ainda não está boa o suficiente.

## Perguntas que quero saber responder ao final

- Por que o cache na borda é o que torna um evento como a Copa viável, e como medir isso (hit ratio)?
- Como um cluster Kubernetes reage, na prática, a uma onda súbita de tráfego (HPA, provisionamento de nodes)?
- Como definir e monitorar SLOs de latência e disponibilidade em um serviço de streaming?
- O que quebra primeiro sob carga — e como um SRE investiga e responde a isso?
