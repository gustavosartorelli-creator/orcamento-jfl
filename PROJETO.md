# Orçamento por Área (JFL): notas do projeto

## O que é
PWA para os líderes de **manutenção**, **governança** e **recepção** acompanharem o orçamento do próprio departamento, prédio a prédio.
Substitui a planilha "ORÇAMENTO POR ÁREA.xlsx" da Sara (analista administrativa do JML).

Perfis por PIN de 4 dígitos (`orc_usuarios`, independente do app de governança):
- **admin**: edita linhas, importa pagamentos, cadastra a equipe. Sara = admin do JML; Gustavo = admin de todos os prédios (`predio_id` nulo).
- **gestor**: vê todos os departamentos do prédio (ou de todos, se `predio_id` nulo).
- **lider**: vê só o próprio departamento do próprio prédio.

## Onde está cada coisa
- **App:** `index.html` (HTML, CSS e JS num arquivo só). Sem service worker: os dados são sempre buscados online.
- **Banco:** o mesmo Supabase do app de governança (`zzppioqshjiltllfpttg`), tabelas com prefixo `orc_`. Os prédios vêm de `gov_predios`.
- **Mudanças de banco:** `sql/` (uma por data).
- **Testar localmente:** `powershell -File .claude/serve.ps1` e abrir http://localhost:8787.
- **Publicação:** ainda não publicado. Ideia: repositório próprio no GitHub + projeto Netlify `orcamento-jfl`, como o de governança.

## Como o realizado é calculado
Cada linha (`orc_linhas`) tem `fonte`:
- `pagamentos` (marcada **AUTO** no app): soma dos pagamentos importados (`orc_pagamentos`) do mesmo prédio e ano cuja
  **Finalidade** está em `regra_finalidades` (comparação sem acento e sem pontuação, `orc__chave`) e cuja **Descrição Vertical**
  contém OPEX/CAPEX conforme `regra_vertical`.
- `manual`: valor digitado pela administração em `realizado_manual`. É o caso das linhas de condomínio, até integrar com a Umuarama.

Os pagamentos vêm da planilha **2026-Controle de pagamentos-OPR00291_OPEX-CAPEX.xlsx**
(SharePoint `OPR_MonthlyReports` → `1-GERÊNCIA/1-MONTLHY/2026/1-MONTLHY`), uma aba por prédio (Vhouse, JML747, AVNU, JFL125, VO699).
O admin importa pelo botão "Importar pagamentos": o app lê o .xlsx no navegador (SheetJS) e chama `orc_importar`, que **substitui**
todos os pagamentos daquele prédio e ano. Datas inválidas na planilha (ex.: 30/02/2026) entram sem data.

## RPCs
orc_login, orc_painel, orc_detalhe, orc_importar, orc_finalidades, orc_salvar_linha, orc_excluir_linha, orc_usuarios_listar, orc_salvar_usuario.
Todas `SECURITY DEFINER`, validando o PIN (`orc__usuario`), o prédio (`orc__predio`) e, nas de edição, o papel admin (`orc__admin`).

## Pendências
- **Eletros / Equipamentos (OPEX)** e **Mobiliário (CapEx)** do JML estão com realizado digitado, porque a soma dos pagamentos diverge
  da planilha da Sara (Eletros OPEX: R$ 82.639,98 nos pagamentos x R$ 10.840 da Sara; parte são locações de TV da RENTV lançadas como
  ELETROS/EQUIPAMENTOS. Mobiliário: R$ 20.820 x R$ 44.320). Confirmar com a Sara e trocar para AUTO no editor.
- A seção "Manutenção Comercial" (códigos 3092 e 3098) estava sem título na planilha; o nome foi deduzido. Confirmar.
- Leitura automática do SharePoint: pedir à TI um app no Azure (Microsoft Graph, `Sites.Selected` só no site OPR_MonthlyReports) e uma
  Edge Function com agendamento que chame `orc_importar`.
- Condomínio: integrar com a plataforma da Umuarama (falta saber se há API ou exportação).
- Cadastrar o orçamento dos outros prédios e os PINs dos líderes (a Sara faz pelo botão "Equipe").
