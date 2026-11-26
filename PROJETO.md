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
- **Site:** https://gustavosartorelli-creator.github.io/orcamento-jfl/ (GitHub Pages, branch `main`, pasta raiz). Publica sozinho a
  cada commit na `main`, em cerca de 1 minuto.
- **Repositório:** https://github.com/gustavosartorelli-creator/orcamento-jfl (**público**, exigência do Pages no plano gratuito;
  os dados continuam protegidos pelo PIN nas RPCs). Nunca coloque PINs ou chaves secretas nos arquivos.
- **Como publicar:** envie os arquivos alterados para a `main` (sem Git, pelo GitHub no Chrome:
  *Add file → Upload files → Commit directly to main*; para a pasta `sql/`, use a URL `.../upload/main/sql`). Não envie a pasta `.claude/`.
- **Netlify:** existe também o projeto `orcamento-jfl` (https://orcamento-jfl.netlify.app), criado em 03/11/2026 com a equipe sem
  créditos, por isso nunca publicou. Ciclo de cobrança: 22 a 21 de cada mês. Pode ser apagado ou usado depois.

## Como o realizado é calculado
Cada linha (`orc_linhas`) tem `fonte`:
- `pagamentos` (marcada **AUTO** no app): soma dos pagamentos importados (`orc_pagamentos`) do mesmo prédio e ano cuja
  **Finalidade** está em `regra_finalidades` (comparação sem acento e sem pontuação, `orc__chave`) e cuja **Descrição Vertical**
  contém OPEX/CAPEX conforme `regra_vertical`. Desde 26/11/2026 a regra pode ter destino: `CAPEX UNIDADES`, `CAPEX CONDOMINIO`
  (idem OPEX) pega só a Descrição Vertical com "Unidades" ou "Condomínio" (`orc__vert_ok`). Ex.: a linha 195 Melhorias e Obras da
  Manutenção (orçado R$ 160 mil, aba "Capex JFL 2026 - JML747" do ORÇAMENTO 2026 PARA CONSULTA) usa `CAPEX UNIDADES`, para não
  somar o rateio mensal de obras do condomínio (LUMINUS JARDINS, R$ 39.679,80/mês, Capex Condomínio).
  O rateio tem linha própria na Manutenção ("Melhorias e Obras (rateio condomínio)", `CAPEX CONDOMINIO`), orçado R$ 473.691:
  soma da parte da SPE nos itens classificados como Capex do "Investimento (M&O)" (aba "Orç CONSOLIDADO", Melhorias e Obras - 00195).
- **Itens orçados** (`orc_itens`, RPC `orc_itens_linha`): o que compõe o orçado de uma linha, mostrado no detalhe abaixo do gráfico.
  Carregados à mão (sem tela de edição) para as 4 linhas de Melhorias e Obras da Manutenção: 195 Unidades (aba Capex, R$ 160 mil),
  rateio (parte da SPE nos itens Capex do Orç CONSOLIDADO, R$ 473.691) e condomínio Geral/Residencial (aba Investimento (M&O), valores
  totais do condomínio; a soma não bate com o orçado da Umuarama e o app avisa isso no detalhe).
- Na tela, um seletor **Todos / Condomínio / SPE** (só aparece se o departamento tem as duas origens; fica salvo no aparelho).
- `umuarama` (também **AUTO**): soma do gasto da conta da Umuarama (`orc_condominio`) no ano, pelo bloco (`regra_bloco`) e pela
  conta (`regra_conta`, chave sem acento). É o caso das linhas de condomínio do JML desde 03/11/2026.
- `manual`: valor digitado pela administração em `realizado_manual`. Não tem valor por mês, então some no filtro de mês.

### Condomínio (Umuarama)
Portal: https://servc9-1.webware.com.br (CondoPro; condomínio 63 Luminus Jardins). Relatório **Finanças → Prestação de Contas Desm.
Online → Orçado e Gasto**: escolha o mês, *Consultar*, *Exportar Excel*. No app, "Importar condomínio" aceita vários arquivos de uma vez;
cada mês substitui o que havia daquele mês (`orc_importar_condominio`).
O relatório vem em blocos sem título (no JML: 1 = Geral, 2 = Residencial, 3 = Comercial). O app separa os blocos quando um grupo
(ex.: "Recepção - Despesa Fixa") se repete. Se a Umuarama mudar o layout, confira na prévia se continuam saindo 3 blocos.
Carga inicial: jan a out/2026 lidos da tela do portal, nov/2026 pelo Excel. Os valores bateram com a planilha da Sara até setembro.
Sem API: a importação automática exigiria guardar a senha do portal num servidor, por isso ficou manual (1 arquivo por mês).

### Condomínio completo (aba privada, desde 24/11/2026)
Aba **"Condomínio completo"** (departamento `condominio`) com uma linha por conta do relatório (todo o plano de contas da Umuarama),
exceto as contas já ligadas às linhas dos líderes. As linhas têm `privada = true` e só aparecem para usuários com
`orc_usuarios.ve_privadas` (hoje só o Gustavo); as RPCs escondem e bloqueiam essas linhas para os demais, inclusive a Sara.
A cada importação da Umuarama, `orc__sync_privadas` cria linhas para contas novas e recalcula o orçado delas
(orçado mês = último mês importado; orçado ano = meses importados + último orçado x meses que faltam), então editar o orçado
de uma linha privada à mão não dura até a próxima importação. Seção = bloco · grupo (`orc__secao`).

Os pagamentos vêm da planilha **2026-Controle de pagamentos-OPR00291_OPEX-CAPEX.xlsx**
(SharePoint `OPR_MonthlyReports` → `1-GERÊNCIA/1-MONTLHY/2026/1-MONTLHY`), uma aba por prédio (Vhouse, JML747, AVNU, JFL125, VO699).
O admin importa pelo botão "Importar pagamentos": o app lê o .xlsx no navegador (SheetJS) e chama `orc_importar`, que **substitui**
todos os pagamentos daquele prédio e ano. Datas inválidas na planilha (ex.: 30/02/2026) entram sem data.

### Importação automática (desde 18/11/2026, só JML)
Tarefa agendada do Claude desktop **"Orçamento JFL: importar pagamentos do SharePoint"** (`orcamento-jfl-pagamentos-sharepoint`,
dias úteis às 8h, roda neste PC com o app do Claude aberto). Lê a aba JML747 pelo conector Microsoft 365 (sem app no Azure),
converte com `automacao/importar-pagamentos.ps1` (mesmas regras do `lerAba` do app) e chama `orc_importar`. Pula se a planilha
não mudou desde a última importação e não importa se o total cair mais de 10%.
Usa o usuário admin **"Robô SharePoint"** (`orc_usuarios`, JML); o PIN fica só em `%USERPROFILE%\.orcamento-jfl\robo.json`, fora do repositório.
Teste manual: `powershell -File automacao\importar-pagamentos.ps1 -Arquivo <texto da aba> -Simular`.

## RPCs
orc_login, orc_painel, orc_detalhe, orc_importar, orc_importar_condominio, orc_finalidades, orc_contas, orc_salvar_linha, orc_excluir_linha,
orc_usuarios_listar, orc_salvar_usuario.
Todas `SECURITY DEFINER`, validando o PIN (`orc__usuario`), o prédio (`orc__predio`) e, nas de edição, o papel admin (`orc__admin`).

## Pendências
- **Eletros / Equipamentos (OPEX)** e **Mobiliário (CapEx)** do JML estão com realizado digitado, porque a soma dos pagamentos diverge
  da planilha da Sara (Eletros OPEX: R$ 82.639,98 nos pagamentos x R$ 10.840 da Sara; parte são locações de TV da RENTV lançadas como
  ELETROS/EQUIPAMENTOS. Mobiliário: R$ 20.820 x R$ 44.320). Confirmar com a Sara e trocar para AUTO no editor.
- A seção "Manutenção Comercial" (códigos 3092 e 3098) estava sem título na planilha; o nome foi deduzido. Confirmar.
- Leitura automática do SharePoint 100% na nuvem (sem depender deste PC): pedir à TI um app no Azure (Microsoft Graph, `Sites.Selected`
  só no site OPR_MonthlyReports) e uma Edge Function com agendamento que chame `orc_importar`. Hoje roda pela tarefa agendada acima.
- Em nov/2026 a Sara passou a lançar a RENTV como finalidade **LOCAÇÃO DE TVS** (27 lançamentos, R$ 220 mil no ano), que não está em
  nenhuma linha. Também apareceu **"Azulejos e Cer. - Pisos e Par."** (R$ 26 mil). Decidir em qual linha entram.
- Cadastrar o orçamento dos outros prédios e os PINs dos líderes (a Sara faz pelo botão "Equipe").
