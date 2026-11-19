// =====================================================================
// Painel de cooperativas de crédito (Sicoob vs mercado) — Power Query (M)
// Versão final, conferida contra as APIs do Banco Central em nov/2026.
// =====================================================================
//
// FONTES (todas do Banco Central, nenhum dado digitado):
//   - IF.data (olinda.bcb.gov.br/.../IFDATA): balanço e carteira de
//     crédito por instituição, trimestral.
//   - BcBase (olinda.bcb.gov.br/.../BcBase): cadastro de cooperativas
//     (nome fantasia e sigla, usados para identificar o sistema).
//   - SGS (api.bcb.gov.br): Selic (1178), CDI (4389), IPCA (433).
//
// REGRAS APLICADAS:
//   1. Só cooperativas SINGULARES: Tcb = "B3S" no cadastro do IF.data.
//      As Centrais (Tcb = "B3C") ficam de fora porque o ativo delas é,
//      em grande parte, dinheiro das singulares depositado nelas.
//      Somar as duas contaria o mesmo dinheiro duas vezes.
//   2. Cooperativa "ativa" = tem valor reportado no trimestre. O
//      cadastro inclui cooperativas encerradas ou incorporadas.
//   3. Sistema (Sicoob, Sicredi, Cresol, Unicred) identificado por:
//      razão social → nome fantasia → sigla, nessa ordem. Não existe
//      campo oficial de vínculo cooperativa→sistema nos dados abertos.
//      A Ailos não é identificável (as singulares dela não usam
//      "Ailos" no nome) e entra em "Outros".
//   4. Trimestres de 2025-T1 em diante: em 2025 o Bacen mudou o layout
//      (nova norma contábil). "Carteira de Crédito Classificada" virou
//      "Carteira de Crédito". Misturar antes e depois quebra a série.
//   5. Table.Distinct nos valores: o trimestre 202509 vem TRIPLICADO
//      na API.
//   6. TipoInstituicao = 1: traz as cooperativas, o Índice de Basileia
//      e os relatórios de carteira de crédito (9, 11 e 13).
//   7. Timeout de 10 min: a API demora de 50 a 130 s por chamada e o
//      Power BI desiste em 100 s por padrão.
//
// TEMPO DE CARGA: cerca de 10 a 15 minutos.
// Credenciais: Anônimo. Privacidade: marcar "Ignorar os Níveis de
// Privacidade" nas opções do arquivo.
// Erro "(500): Internal Server Error" em olinda.bcb.gov.br é
// instabilidade do serviço do Bacen, não da consulta: tente mais tarde.
//
// COMO USAR: cada bloco vira uma Consulta Nula (Editor Avançado), com
// o nome indicado em "NOME". "(intermediária)" = desmarcar
// "Habilitar carga".
// =====================================================================


// ---------------------------------------------------------------------
// 1) Trimestres — lista de trimestres carregados (intermediária)
// ---------------------------------------------------------------------
{"202503", "202506", "202509", "202512", "202603", "202606"}
// NOME: Trimestres
// Para atualizar no futuro, acrescente o trimestre novo no fim da
// lista (ex.: "202609" quando o Bacen publicar).


// ---------------------------------------------------------------------
// 2) UltimoTrimestre (intermediária)
// ---------------------------------------------------------------------
List.Last(Trimestres)
// NOME: UltimoTrimestre


// ---------------------------------------------------------------------
// 3) fn_IFData_Cadastro (função)
// ---------------------------------------------------------------------
(AnoMes as text, optional Filtro as nullable text) as table =>
let
    url = "https://olinda.bcb.gov.br/olinda/servico/IFDATA/versao/v1/odata/IfDataCadastro(AnoMes=@AnoMes)?@AnoMes="
        & AnoMes & "&$format=json"
        & (if Filtro = null then "" else "&$filter=" & Uri.EscapeDataString(Filtro)),
    origem = Json.Document(Web.Contents(url, [Timeout = #duration(0, 0, 10, 0)])),
    tabela = Table.FromRecords(origem[value])
in
    tabela
// NOME: fn_IFData_Cadastro


// ---------------------------------------------------------------------
// 4) fn_IFData_Valores (função)
// ---------------------------------------------------------------------
(AnoMes as text, TipoInstituicao as text, Relatorio as text, optional Filtro as nullable text) as table =>
let
    url = "https://olinda.bcb.gov.br/olinda/servico/IFDATA/versao/v1/odata/IfDataValores(AnoMes=@AnoMes,TipoInstituicao=@TipoInstituicao,Relatorio=@Relatorio)"
        & "?@AnoMes=" & AnoMes & "&@TipoInstituicao=" & TipoInstituicao & "&@Relatorio='" & Relatorio & "'&$format=json"
        & (if Filtro = null then "" else "&$filter=" & Uri.EscapeDataString(Filtro)),
    origem = Json.Document(Web.Contents(url, [Timeout = #duration(0, 0, 10, 0)])),
    tabela = Table.FromRecords(origem[value]),
    semDuplicatas = Table.Distinct(tabela)
in
    semDuplicatas
// NOME: fn_IFData_Valores


// ---------------------------------------------------------------------
// 5) BcBase_Cooperativas — nome fantasia e sigla (intermediária)
// ---------------------------------------------------------------------
let
    dataBase = Date.ToText(Date.From(DateTime.LocalNow()), "MM-dd-yyyy"),
    url = "https://olinda.bcb.gov.br/olinda/servico/BcBase/versao/v2/odata/Cooperativas(dataBase=@dataBase)?@dataBase='"
        & dataBase & "'&$format=json",
    origem = Json.Document(Web.Contents(url, [Timeout = #duration(0, 0, 10, 0)])),
    tabela = Table.FromRecords(origem[value]),
    colunas = Table.SelectColumns(tabela, {"codigoCNPJ8", "nomeFantasia", "siglaDaPessoaJuridica"})
in
    colunas
// NOME: BcBase_Cooperativas


// ---------------------------------------------------------------------
// 6) Dim_Instituicao — uma linha por cooperativa singular, com Sistema
// ---------------------------------------------------------------------
let
    Cadastros = Table.Combine(List.Transform(Trimestres, each fn_IFData_Cadastro(_, "Tcb eq 'B3S'"))),
    Ordenado = Table.Buffer(Table.Sort(Cadastros, {{"Data", Order.Descending}})),
    UmaPorCodigo = Table.Distinct(Ordenado, {"CodInst"}),
    Colunas = Table.SelectColumns(UmaPorCodigo, {"CodInst", "NomeInstituicao", "Uf", "Municipio"}),
    ComBcBase = Table.NestedJoin(Colunas, "CodInst", BcBase_Cooperativas, "codigoCNPJ8", "BC", JoinKind.LeftOuter),
    Expandido = Table.ExpandTableColumn(ComBcBase, "BC", {"nomeFantasia", "siglaDaPessoaJuridica"}, {"NomeFantasia", "Sigla"}),
    Classifica = (t as nullable text) as nullable text =>
        let u = if t = null then "" else Text.Upper(t) in
        if Text.Contains(u, "SICOOB") then "Sicoob"
        else if Text.Contains(u, "SICREDI") then "Sicredi"
        else if Text.Contains(u, "UNICRED") then "Unicred"
        else if Text.Contains(u, "CRESOL") then "Cresol"
        else null,
    ComSistema = Table.AddColumn(Expandido, "Sistema", each
        let a = Classifica([NomeInstituicao]), b = Classifica([NomeFantasia]), c = Classifica([Sigla]) in
        if a <> null then a else if b <> null then b else if c <> null then c else "Outros", type text)
in
    ComSistema
// NOME: Dim_Instituicao
// Cooperativas ativas em 2026-T2 (medida "Cooperativas Ativas" no
// Power BI): Sicoob 299, Sicredi 99, Cresol 55, Unicred 23,
// Outros 234 — total 710.


// ---------------------------------------------------------------------
// 7) fn_Fato_Resumo_Trimestre (função)
// ---------------------------------------------------------------------
(AnoMes as text) as table =>
let
    Singulares = Table.SelectColumns(fn_IFData_Cadastro(AnoMes, "Tcb eq 'B3S'"), {"CodInst"}),
    Valores = fn_IFData_Valores(AnoMes, "1", "1",
        "NomeColuna eq 'Ativo Total' or NomeColuna eq 'Captações' or NomeColuna eq 'Carteira de Crédito' or NomeColuna eq 'Patrimônio Líquido' or NomeColuna eq 'Lucro Líquido' or NomeColuna eq 'Índice de Basileia'"),
    SoSingulares = Table.NestedJoin(Valores, "CodInst", Singulares, "CodInst", "S", JoinKind.Inner),
    Colunas = Table.SelectColumns(SoSingulares, {"CodInst", "AnoMes", "NomeColuna", "Saldo"}),
    ComTipos = Table.TransformColumnTypes(Colunas, {{"Saldo", type number}}),
    ComData = Table.AddColumn(ComTipos, "Data", each
        Date.EndOfMonth(#date(Number.FromText(Text.Start([AnoMes], 4)), Number.FromText(Text.End([AnoMes], 2)), 1)),
        type date)
in
    ComData
// NOME: fn_Fato_Resumo_Trimestre


// ---------------------------------------------------------------------
// 8) Fato_IFData — Ativo, Captações, Carteira, PL, Lucro, Basileia
//    por cooperativa e trimestre (relatório 1, Resumo)
// ---------------------------------------------------------------------
let
    Tabelas = List.Transform(Trimestres, each fn_Fato_Resumo_Trimestre(_)),
    Combinado = Table.Combine(Tabelas)
in
    Combinado
// NOME: Fato_IFData
// Saldo em reais. Índice de Basileia vem como fração (0,19 = 19%).


// ---------------------------------------------------------------------
// 9) Fato_Carteira_Modalidade — carteira ativa PF e PJ por modalidade,
//    último trimestre (relatórios 11 e 13 do IF.data)
// ---------------------------------------------------------------------
let
    AnoMes = UltimoTrimestre,
    Singulares = Table.SelectColumns(fn_IFData_Cadastro(AnoMes, "Tcb eq 'B3S'"), {"CodInst"}),
    PF = Table.AddColumn(fn_IFData_Valores(AnoMes, "1", "11", "NomeColuna eq 'Total'"), "Tipo", each "Pessoa Física", type text),
    PJ = Table.AddColumn(fn_IFData_Valores(AnoMes, "1", "13", "NomeColuna eq 'Total'"), "Tipo", each "Pessoa Jurídica", type text),
    Ambos = Table.Combine({PF, PJ}),
    SoSingulares = Table.NestedJoin(Ambos, "CodInst", Singulares, "CodInst", "S", JoinKind.Inner),
    Colunas = Table.SelectColumns(SoSingulares, {"CodInst", "AnoMes", "Tipo", "Grupo", "Saldo"}),
    Renomeado = Table.RenameColumns(Colunas, {{"Grupo", "Modalidade"}}),
    ComTipos = Table.TransformColumnTypes(Renomeado, {{"Saldo", type number}}),
    ComData = Table.AddColumn(ComTipos, "Data", each
        Date.EndOfMonth(#date(Number.FromText(Text.Start([AnoMes], 4)), Number.FromText(Text.End([AnoMes], 2)), 1)),
        type date)
in
    ComData
// NOME: Fato_Carteira_Modalidade


// ---------------------------------------------------------------------
// 10) Fato_Carteira_Regiao — carteira ativa por região do tomador,
//     último trimestre (relatório 9 do IF.data)
// ---------------------------------------------------------------------
let
    AnoMes = UltimoTrimestre,
    Singulares = Table.SelectColumns(fn_IFData_Cadastro(AnoMes, "Tcb eq 'B3S'"), {"CodInst"}),
    Valores = fn_IFData_Valores(AnoMes, "1", "9"),
    SoSingulares = Table.NestedJoin(Valores, "CodInst", Singulares, "CodInst", "S", JoinKind.Inner),
    SoRegioes = Table.SelectRows(SoSingulares, each List.Contains({"Norte", "Nordeste", "Centro-oeste", "Sudeste", "Sul"}, [NomeColuna])),
    Colunas = Table.SelectColumns(SoRegioes, {"CodInst", "AnoMes", "NomeColuna", "Saldo"}),
    Renomeado = Table.RenameColumns(Colunas, {{"NomeColuna", "Regiao"}}),
    Padronizado = Table.ReplaceValue(Renomeado, "Centro-oeste", "Centro-Oeste", Replacer.ReplaceValue, {"Regiao"}),
    ComTipos = Table.TransformColumnTypes(Padronizado, {{"Saldo", type number}}),
    ComData = Table.AddColumn(ComTipos, "Data", each
        Date.EndOfMonth(#date(Number.FromText(Text.Start([AnoMes], 4)), Number.FromText(Text.End([AnoMes], 2)), 1)),
        type date)
in
    ComData
// NOME: Fato_Carteira_Regiao
// Ficam de fora as linhas "Total Geral", "Total Exterior" e "Região
// não Informada". Por isso o total por região fica ~R$ 30 mi abaixo do
// total por modalidade no Sicoob (199,77 x 199,80 bi em 2026-T2).


// ---------------------------------------------------------------------
// 11) fn_SGS (função)
// ---------------------------------------------------------------------
(codigoSerie as text, dataInicial as text, dataFinal as text) as table =>
let
    url = "https://api.bcb.gov.br/dados/serie/bcdata.sgs." & codigoSerie
        & "/dados?formato=json&dataInicial=" & dataInicial & "&dataFinal=" & dataFinal,
    origem = Json.Document(Web.Contents(url, [Timeout = #duration(0, 0, 5, 0)])),
    tabela = Table.FromRecords(origem),
    comData = Table.AddColumn(tabela, "Data", each
        #date(Number.FromText(Text.End([data], 4)), Number.FromText(Text.Middle([data], 3, 2)), Number.FromText(Text.Start([data], 2))),
        type date),
    comValor = Table.AddColumn(comData, "Valor", each Number.FromText([valor], "en-US"), type number),
    final = Table.SelectColumns(comValor, {"Data", "Valor"})
in
    final
// NOME: fn_SGS


// ---------------------------------------------------------------------
// 12) Fato_Macro — Selic (1178) e CDI (4389) em % a.a., IPCA mensal (433)
// ---------------------------------------------------------------------
let
    Selic = Table.AddColumn(fn_SGS("1178", "01/01/2024", "31/12/2026"), "Indicador", each "Selic", type text),
    CDI = Table.AddColumn(fn_SGS("4389", "01/01/2024", "31/12/2026"), "Indicador", each "CDI", type text),
    IPCA = Table.AddColumn(fn_SGS("433", "01/01/2024", "31/12/2026"), "Indicador", each "IPCA", type text),
    Unidas = Table.Combine({Selic, CDI, IPCA})
in
    Unidas
// NOME: Fato_Macro
// No período carregado, as séries 1178 e 4389 têm os mesmos valores.


// ---------------------------------------------------------------------
// 13) Dim_Sistema
// ---------------------------------------------------------------------
Table.FromRows({{"Sicoob"}, {"Sicredi"}, {"Unicred"}, {"Cresol"}, {"Outros"}}, {"Sistema"})
// NOME: Dim_Sistema


// ---------------------------------------------------------------------
// 14) Dim_UF_Regiao
// ---------------------------------------------------------------------
Table.FromRows(
    {
        {"AC","Norte"},{"AM","Norte"},{"AP","Norte"},{"PA","Norte"},{"RO","Norte"},{"RR","Norte"},{"TO","Norte"},
        {"AL","Nordeste"},{"BA","Nordeste"},{"CE","Nordeste"},{"MA","Nordeste"},{"PB","Nordeste"},{"PE","Nordeste"},{"PI","Nordeste"},{"RN","Nordeste"},{"SE","Nordeste"},
        {"DF","Centro-Oeste"},{"GO","Centro-Oeste"},{"MT","Centro-Oeste"},{"MS","Centro-Oeste"},
        {"ES","Sudeste"},{"MG","Sudeste"},{"RJ","Sudeste"},{"SP","Sudeste"},
        {"PR","Sul"},{"RS","Sul"},{"SC","Sul"}
    },
    {"UF", "Regiao"}
)
// NOME: Dim_UF_Regiao


// ---------------------------------------------------------------------
// 15) Dim_Calendario
// ---------------------------------------------------------------------
let
    DataInicio = #date(2024, 1, 1),
    DataFim = #date(2026, 12, 31),
    ListaDatas = List.Dates(DataInicio, Duration.Days(DataFim - DataInicio) + 1, #duration(1, 0, 0, 0)),
    Tabela = Table.FromList(ListaDatas, Splitter.SplitByNothing(), {"Data"}),
    TipoData = Table.TransformColumnTypes(Tabela, {{"Data", type date}}),
    ComAno = Table.AddColumn(TipoData, "Ano", each Date.Year([Data]), Int64.Type),
    ComTrimestre = Table.AddColumn(ComAno, "Trimestre", each "T" & Text.From(Date.QuarterOfYear([Data])), type text),
    ComAnoTrimestre = Table.AddColumn(ComTrimestre, "AnoTrimestre", each Text.From([Ano]) & "-" & [Trimestre], type text),
    ComOrdem = Table.AddColumn(ComAnoTrimestre, "OrdemTrimestre", each [Ano] * 10 + Date.QuarterOfYear([Data]), Int64.Type),
    ComMes = Table.AddColumn(ComOrdem, "Mes", each Date.Month([Data]), Int64.Type)
in
    ComMes
// NOME: Dim_Calendario
// Depois de carregar: Marcar como Tabela de Datas (coluna Data) e
// AnoTrimestre > Classificar por Coluna > OrdemTrimestre.
// As colunas OrdemMes e MesAno são calculadas em DAX (ver medidas.dax).
