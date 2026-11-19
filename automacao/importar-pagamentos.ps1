<#
  Importa os pagamentos da planilha "2026-Controle de pagamentos-OPR00291_OPEX-CAPEX.xlsx" (SharePoint OPR_MonthlyReports)
  para o app, com as mesmas regras do botão "Importar pagamentos" (lerAba no index.html).

  Entrada: o texto da aba como o conector do Microsoft 365 do Claude devolve (read_resource):
  uma linha "## Sheet: <aba> ...", o cabeçalho e as linhas separadas por TAB, valores como "18.265,42" e datas "dd/mm/aaaa".

  O PIN NÃO fica aqui (o repositório é público): vem de %USERPROFILE%\.orcamento-jfl\robo.json  ->  { "pin": "0000" }
  Usuário do PIN: "Robô SharePoint" (admin do JML em orc_usuarios).

  Uso:
    powershell -File importar-pagamentos.ps1 -Arquivo <texto.txt> [-Aba JML747] [-Predio jml] [-Ano 2026] [-Simular]
#>
param(
  [Parameter(Mandatory = $true)][string]$Arquivo,
  [string]$Aba = 'JML747',
  [string]$Predio = 'jml',
  [int]$Ano = 2026,
  [string]$NomeArquivo = '2026-Controle de pagamentos-OPR00291_OPEX-CAPEX.xlsx (SharePoint, automático)',
  [switch]$Simular
)
$ErrorActionPreference = 'Stop'
$SUPABASE_URL = 'https://zzppioqshjiltllfpttg.supabase.co'
$SUPABASE_KEY = 'sb_publishable_gESIDVWQtHFMkCDzwP7w2g_17eYXfzK'   # chave pública, a mesma do index.html
$MESES = @('jan','fev','mar','abr','mai','jun','jul','ago','set','out','nov','dez')

# Igual a chave() do app / orc__chave do banco: sem acento, maiúsculas, só letras e números.
function Chave([string]$t) {
  if ($null -eq $t) { return '' }
  $n = $t.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($ch in $n.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
  }
  return ($sb.ToString().ToUpperInvariant() -replace '[^A-Z0-9]', '')
}

# dd/mm/aaaa -> aaaa-mm-dd; datas impossíveis (30/02) viram nulas, como no app.
function LerData([string]$v) {
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  $m = [regex]::Match($v.Trim(), '^(\d{1,2})/(\d{1,2})/(\d{4})$')
  if (-not $m.Success) { return $null }
  $d = [int]$m.Groups[1].Value; $mo = [int]$m.Groups[2].Value; $y = [int]$m.Groups[3].Value
  if ($mo -lt 1 -or $mo -gt 12 -or $d -lt 1 -or $d -gt [DateTime]::DaysInMonth($y, $mo)) { return $null }
  return ('{0:D4}-{1:D2}-{2:D2}' -f $y, $mo, $d)
}

# "nov-26" -> 2026-11-01
function LerMes([string]$v) {
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  $m = [regex]::Match($v.Trim().ToLower(), '^([a-zç]{3})[-/ ]?(\d{2}|\d{4})$')
  if (-not $m.Success) { $d = LerData $v; if ($d) { return $d.Substring(0, 8) + '01' } else { return $null } }
  $i = [array]::IndexOf($MESES, $m.Groups[1].Value)
  if ($i -lt 0) { return $null }
  $y = [int]$m.Groups[2].Value; if ($y -lt 100) { $y += 2000 }
  return ('{0:D4}-{1:D2}-01' -f $y, ($i + 1))
}

# "18.265,42" / "1500" / "R$ 1.234,56" / "(188,00)" -> número
function LerValor([string]$v) {
  if ($null -eq $v) { return $null }
  $t = ($v -replace 'R\$|\s', '')
  if (-not $t) { return $null }
  $neg = $false
  if ($t -match '^\((.*)\)$') { $t = $Matches[1]; $neg = $true }
  if ($t.StartsWith('-')) { $t = $t.Substring(1); $neg = -not $neg }
  if ($t.Contains(',')) { $t = $t.Replace('.', '').Replace(',', '.') }
  elseif ($t -match '^\d{1,3}(\.\d{3})+$') { $t = $t.Replace('.', '') }   # "1.500" = mil e quinhentos
  $x = 0.0
  if (-not [double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { return $null }
  if ($neg) { $x = -$x }
  return [math]::Round($x, 2)
}

# ---------- Ler a aba do texto ----------
$linhas = [IO.File]::ReadAllLines((Resolve-Path $Arquivo), [Text.Encoding]::UTF8)
$ini = -1
for ($i = 0; $i -lt $linhas.Length; $i++) { if ($linhas[$i] -match ('^## Sheet: ' + [regex]::Escape($Aba) + '\b')) { $ini = $i; break } }
if ($ini -lt 0) { throw "Aba '$Aba' não encontrada no arquivo." }

$hi = -1
for ($i = $ini + 1; $i -lt $linhas.Length -and $i -lt $ini + 30; $i++) {
  $ks = $linhas[$i].Split("`t") | ForEach-Object { Chave $_ }
  if (($ks -contains 'FINALIDADE') -and ($ks -contains 'VALOR')) { $hi = $i; break }
}
if ($hi -lt 0) { throw "Cabeçalho (Finalidade / Valor) não encontrado na aba '$Aba'." }

$col = @{}
$cab = $linhas[$hi].Split("`t")
for ($c = 0; $c -lt $cab.Length; $c++) { $k = Chave $cab[$c]; if ($k -and -not $col.ContainsKey($k)) { $col[$k] = $c } }
foreach ($k in 'MES','DATALANC','VALOR','FINALIDADE','DESCRICAOVERTICAL') { if (-not $col.ContainsKey($k)) { throw "Coluna '$k' não encontrada no cabeçalho." } }

function G($cel, [string]$k) { if (-not $col.ContainsKey($k) -or $col[$k] -ge $cel.Length) { return $null }; return $cel[$col[$k]] }
function Txt($cel, [string]$k) { $v = G $cel $k; if ($null -eq $v) { return '' }; return $v.Trim() }

$out = New-Object System.Collections.ArrayList
$invalidas = New-Object System.Collections.ArrayList
for ($i = $hi + 1; $i -lt $linhas.Length; $i++) {
  $l = $linhas[$i]
  if ($l -match '^(## Sheet: |Formulas:)' ) { break }
  if ([string]::IsNullOrWhiteSpace($l)) { continue }
  $cel = $l.Split("`t")
  $valor = LerValor (G $cel 'VALOR')
  if ($null -eq $valor -or $valor -eq 0) { continue }
  $bruta = G $cel 'DATALANC'
  $data = LerData $bruta
  if (-not $data -and -not [string]::IsNullOrWhiteSpace($bruta)) { [void]$invalidas.Add($bruta.Trim()) }
  $mes = LerMes (G $cel 'MES')
  if (-not $mes -and $data) { $mes = $data.Substring(0, 8) + '01' }
  [void]$out.Add([ordered]@{
    mes = $mes; data = $data; cod = (Txt $cel 'COD'); descricao = (Txt $cel 'DESCRICAOCOD'); fornecedor = (Txt $cel 'FORNECEDOR')
    nf = (Txt $cel 'COMPLEMENTONF'); finalidade = (Txt $cel 'FINALIDADE'); vertical = (Txt $cel 'DESCRICAOVERTICAL'); valor = $valor
    venc = (LerData (G $cel 'DATAVENC')); pgto = (LerData (G $cel 'DATAPGTO'))
  })
}

$total = ($out | ForEach-Object { $_.valor } | Measure-Object -Sum).Sum
Write-Output ("Aba {0}: {1} lançamentos, total R$ {2:N2}" -f $Aba, $out.Count, $total)
if ($invalidas.Count) { Write-Output ("Datas inválidas (entram sem data): {0}" -f (($invalidas | Select-Object -First 5) -join ', ')) }
$out | Group-Object { $_.mes } | Sort-Object Name | ForEach-Object {
  Write-Output ("  {0}: {1} lanç., R$ {2:N2}" -f $_.Name, $_.Count, (($_.Group | ForEach-Object { $_.valor } | Measure-Object -Sum).Sum))
}
if ($out.Count -eq 0) { throw 'Nenhum lançamento lido; nada foi importado.' }
if ($Simular) { Write-Output 'Simulação: nada foi enviado.'; return }

# ---------- Enviar para o banco (orc_importar substitui os pagamentos do prédio e ano) ----------
$cfgPath = Join-Path $env:USERPROFILE '.orcamento-jfl\robo.json'
if (-not (Test-Path $cfgPath)) { throw "Falta $cfgPath com o PIN do Robô SharePoint." }
$pin = (Get-Content $cfgPath -Raw | ConvertFrom-Json).pin

$corpo = @{ p_pin = $pin; p_predio = $Predio; p_ano = $Ano; p_arquivo = $NomeArquivo; p_linhas = $out.ToArray() } | ConvertTo-Json -Depth 5 -Compress
$bytes = [Text.Encoding]::UTF8.GetBytes($corpo)
$h = @{ apikey = $SUPABASE_KEY; Authorization = "Bearer $SUPABASE_KEY" }
$r = Invoke-RestMethod -Method Post -Uri "$SUPABASE_URL/rest/v1/rpc/orc_importar" -Headers $h -ContentType 'application/json; charset=utf-8' -Body $bytes
Write-Output ("Importado: {0} linhas, total R$ {1:N2}" -f $r.linhas, [double]$r.total)
