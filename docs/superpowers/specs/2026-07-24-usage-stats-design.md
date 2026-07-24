# Gráfico de 7 dias + uso por modelo (Stats)

## Contexto

Popover hoje (`ContentView` em `App.swift`) mostra só as barras de %
retornadas por `claude -p /usage` (sessão + semanal), vindas de
`UsageStore`. Pedido: acrescentar visão histórica — gráfico diário dos
últimos 7 dias e breakdown de tokens por modelo, inspirado em telas do
Codex CLI (`/stats`) mandadas como referência pelo usuário.

## Fact-check (bloqueante, resolvido)

Claude Code **não tem** um comando `/stats` distinto de `/usage`.
Testado via `claude --safe-mode -p "/stats" --output-format json`: texto
retornado é idêntico ao de `/usage` (%, sem série temporal, sem
breakdown por modelo). As 3 imagens de referência são do **Codex CLI**
(OpenAI), não do Claude Code — não dá pra replicar buscando esse dado
via CLI do claude.

Dado real existe nos **logs locais de sessão**:
`~/.claude/projects/**/*.jsonl` (recursivo, inclui subpastas
`subagents/`). Cada linha `type: assistant` tem `timestamp`, `model` e
`usage` (`input_tokens`, `output_tokens`,
`cache_creation_input_tokens`, `cache_read_input_tokens`). Confirmado
lendo um log real (`4145531b-....jsonl`, sessão desta própria
conversa). Mesma fonte que ferramentas como `ccusage` usam, e
aparentemente a mesma que o `/usage` do claude usa pro bloco
"What's contributing to your limits usage" (que já diz "based on local
sessions on this machine").

## Decisões (via perguntas ao usuário)

- **Métrica:** só tokens (soma de `input + output + cache_creation +
  cache_read`). Sem custo em $ — exigiria tabela de preço por modelo
  mantida à mão, que fica velha a cada mudança de pricing/lançamento de
  modelo.
- **Layout:** tudo numa tela só — novo bloco entra **abaixo** do que já
  existe no popover (barras de sessão/semana, slider de alerta, footer
  com gear), não em aba/tab separada.
- **Escopo de dados:** todas as sessões locais nesta máquina, todos os
  projetos (`~/.claude/projects/**`), incluindo subagentes. Sem
  distinção por projeto/diretório.
- **Fora de escopo (explícito):** limite de créditos, data de reset,
  qualquer coisa em $ estimado.

## Arquitetura

Mesma regra do resto do projeto: single-file `swiftc` build
(`build.sh`), sem SPM/Xcode project — tudo hand-rolled em `App.swift`.

### `DailyModelUsage` (struct)

```swift
struct DailyModelUsage {
    let day: String       // "yyyy-MM-dd", chave local
    let model: String      // raw model id do log, ex: "claude-sonnet-5"
    let tokens: Int         // soma dos 4 campos de usage
}
```

### `StatsStore` (classe, `@MainActor`, `ObservableObject`)

Paralela à `UsageStore` existente, sem compartilhar timer/estado com
ela.

- `@Published var dailyTotals: [(day: String, tokens: Int)]` — 7
  pontos, mais antigo → mais novo, dias sem uso entram com `0` (pra
  gráfico não pular coluna).
- `@Published var modelTotals: [(model: String, tokens: Int)]` — 7
  dias, ordenado desc por tokens.
- `@Published var todayTokens: Int`
- `@Published var mostUsedModel: String?` — primeiro de `modelTotals`.
- `@Published var lastComputed: Date?`

`refresh()` roda em background (`DispatchQueue.global(qos: .utility)`,
igual ao padrão já usado em `runUsageCommand`):

1. `FileManager` enumera `~/.claude/projects` recursivamente
   (`enumerator(at:includingPropertiesForKeys: [.contentModificationDateKey])`).
2. Filtra por extensão `.jsonl` **e** `contentModificationDate` dentro
   dos últimos 7 dias — arquivo não tocado na janela não pode ter
   linha nova dentro dela, pula sem abrir (evita reler histórico de
   meses/GBs).
3. Por arquivo que passa o filtro: lê o conteúdo inteiro
   (`String(contentsOf:)`) e faz `split("\n")` — não um leitor de linha
   em chunks manual (risco de cortar UTF-8 no meio do buffer); o filtro
   de `mtime` já limita isso a arquivos tocados nos últimos 7 dias, na
   prática poucos MB no pior caso visto (~6MB), não justifica streaming
   byte-a-byte. Cada linha vira JSON solto (linhas que não são
   `assistant` ou não têm `usage`/`timestamp`/`model` são ignoradas
   silenciosamente — mesmo espírito tolerante do parser de `/usage`).
4. Descarta entradas com `timestamp` fora da janela de 7 dias (dia
   corrente + 6 anteriores, no fuso local).
5. Acumula em dois dicionários: `[dia: Int]` e `[(dia, modelo): Int]`
     depois:
   - `dailyTotals`: soma por dia (ignora modelo).
   - `modelTotals`: soma por modelo (ignora dia), ordenado desc.
   - `todayTokens`: entrada do dicionário por-dia referente a hoje.
   - `mostUsedModel`: `modelTotals.first?.model`.

Nomes de modelo ficam crus como vêm do log (ex: `claude-sonnet-5`) —
sem mapear pra nome bonito, pra não inventar lookup table que
desatualiza a cada modelo novo (mesmo raciocínio do "sem preço").

### Timer / refresh

Independente do timer de 60s do `UsageStore` (parsing de jsonl é mais
pesado que rodar `/usage`). `StatsStore.init()`:

```swift
refresh()
timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { ... }
```

Sem trigger manual (sem botão de refresh dedicado) — o botão de
refresh existente no header do popover continua só chamando
`store.refresh()` (dados de `/usage`); stats atualiza sozinho no seu
próprio ciclo de 5 min.

## UI

Dentro de `ContentView`, depois do `Divider()` que já existe antes do
footer (`App.swift:475`), novo bloco (antes do footer/gear):

```
Divider()

Text("Hoje: \(todayTokens.formatted()) tokens")   // .font(.caption), .secondary

BarChart de 7 barras usando `Charts` (Swift Charts, disponível desde
macOS 13.0 — bate com `LSMinimumSystemVersion`/target de build já
usado) — `BarMark` por dia, 1 cor (verde, mesma tint das ProgressView
existentes), rótulo de dia no eixo X (ex: "Seg", "Ter"...), altura
fixa ~80pt. Novo `import Charts` e `-framework Charts` no `build.sh`.

VStack "Uso por modelo (7 dias)":
  ForEach modelTotals: HStack { Text(model); Spacer(); Text("\(tokens) (\(pct)%)") }

Text("Most used model: \(mostUsedModel ?? "—")")   // .font(.caption), bold no nome
```

Se `dailyTotals`/`modelTotals` ainda vazios (primeiro `refresh()` não
terminou, ou zero uso local nos últimos 7 dias): mostrar
`Text("Sem dados de uso local nos últimos 7 dias")` no lugar do
gráfico, sem crashar em índice vazio.

## Casos de borda

- **Zero arquivos `.jsonl` recentes:** listas vazias, UI cai no estado
  "sem dados" acima. Não é erro (`errorText` do `UsageStore`
  permanece intocado — stats tem seu próprio estado de vazio, não
  reusa o de erro do usage).
- **Linha de log corrompida/parcial** (jsonl é append-only, pode ter
  linha incompleta se um processo morreu no meio da escrita): `try?`
  no parse de cada linha, ignora silenciosamente — mesmo padrão
  tolerante do parser de `/usage` já existente.
- **Relógio/fuso:** dia é calculado convertendo `timestamp` (UTC no
  log) pro fuso local antes de extrair `yyyy-MM-dd`, pra "hoje" bater
  com o que o usuário vê no relógio do Mac.
- **Arquivos grandes (vistos até ~6MB nesta máquina):** filtro de
  `mtime` antes de abrir evita a maioria; para os poucos que passam,
  ~6MB como string é aceitável (uma vez por arquivo, a cada 5 min).

## Fora de escopo (explícito)

- Custo em $ / tabela de pricing por modelo.
- Limite de créditos, data de reset.
- Filtro por projeto/diretório (é global, todas as sessões locais).
- Nome bonito pro modelo (mostra o id cru do log).
- Export/copy dos dados.

## Testes

Sem suite automatizada (single-file `swiftc`, sem Xcode project).
Verificação manual:

1. Abrir popover com uso real dos últimos 7 dias — conferir que
   `todayTokens`, gráfico e lista de modelos batem com uma soma manual
   (`grep`/`python3` nos mesmos `.jsonl`) pra pelo menos 1 dia.
2. Simular "zero dados": mover temporariamente
   `~/.claude/projects` (ou apontar pra pasta vazia em teste) —
   confirmar estado vazio sem crash.
3. Deixar rodando >5min — confirmar que `StatsStore` recalcula sozinho
   sem travar a UI (parsing em background thread).
4. Rebuild + `open` — confirmar que o resto do popover (barras de
   `/usage`, alerta, gear menu, toggle de login) continua funcionando
   igual, sem regressão.
