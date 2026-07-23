# Painel de alerta no notch (estilo Dynamic Island)

## Contexto

Hoje, ao cruzar o threshold configurável de uso (`alertsEnabled` / `alertThreshold`,
`App.swift:167-180`), o app só toca um som (`NSSound(named: "Glass")`) e troca o
ícone da menu bar. Pedido original: usar o ActivityKit da Apple para mostrar
esse alerta na Dynamic Island.

## Fact-check (bloqueante, resolvido)

`ActivityKit` é framework **iOS/iPadOS/Mac Catalyst only** — não existe para apps
macOS nativos. Referenciar o símbolo em runtime numa app Mac nativa crash.
Dynamic Island é hardware do iPhone; não existe em nenhum Mac. "Live Activity
num Mac pareado" = atividade de um app iPhone espelhada via Continuity no menu
bar do Mac — não é algo que um app Mac cria sozinho.

Fontes: [ActivityKit is Unavailable on macOS](https://twocentstudios.com/2025/01/25/activitykit-unavailable-on-macos/),
[doc oficial ActivityKit](https://developer.apple.com/documentation/ActivityKit/).

Confirmado com o usuário: seguir a linha de apps como o vibe-island
(github.com/vibeislandapp/vibe-island) — painel nativo (`NSPanel`) desenhado
pra parecer uma Dynamic Island, sem ActivityKit real e sem app companion iOS.

## Decisões (via perguntas ao usuário)

- **Trigger:** reusa o threshold configurável já existente (`alertsEnabled` +
  `alertThreshold`), dispara junto do som Glass — mesma condição, sem trigger
  novo em 100%.
- **Conteúdo:** só percentual + label do bloco (ex: "92% · Session"). Sem
  horário de reset, sem múltiplos blocos.
- **Ciclo de vida:** aparece, fica ~5s, some sozinho (fade + scale down).
  Não fica persistente, não tem botão de fechar.
- **Clique:** enquanto visível, clique abre o popover principal do app (mesmo
  destino de clicar no ícone da menu bar).
- **Macs sem notch físico** (Air pré-2021, iMac, mini, monitor externo,
  clamshell com built-in fechado): painel **não aparece**. Comportamento
  atual (som + ícone) continua sendo o único feedback nesses casos. Sem
  posição fallback no topo da tela.

## Arquitetura

Projeto é um único arquivo `App.swift` compilado direto via `swiftc` (sem
Xcode project, sem SPM) — então zero dependências novas, tudo hand-rolled com
AppKit + SwiftUI, consistente com o resto do código.

Componentes novos, todos em `App.swift`:

1. **`NotchAlertView` (SwiftUI)** — pill compacta: ícone de alerta + texto
   "`NN% · Label`". Puramente visual, sem estado próprio.
2. **`NotchAlertController` (classe, `@MainActor`)** — dono do `NSPanel`:
   - `show(percent:label:)`: cria/atualiza o panel, posiciona, anima entrada,
     agenda o auto-dismiss.
   - `dismiss()`: anima saída e fecha o panel.
   - Detecção de notch: percorre `NSScreen.screens` procurando a tela com
     `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` não-nil (API disponível
     desde macOS 12, target do projeto é 13). Se nenhuma tela tiver notch,
     `show` é no-op.
3. **Integração em `checkThresholdAlert`** (`App.swift:167`): além do
   `NSSound`, chama `NotchAlertController.shared.show(...)` na mesma guarda
   de `lastAlertedPercent` (não duplica o disparo a cada refresh).

### Painel (NSPanel)

- `styleMask: [.borderless, .nonactivatingPanel]`, `level: .statusBar` (acima
  da menu bar, pra sobrepor a área do notch).
- `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
  — visível em qualquer space/app em full screen.
- Sem sombra de janela padrão do sistema — sombra vem do próprio SwiftUI
  view, pra não parecer uma janela comum.
- Posição: centralizado no eixo X sobre a área do notch da tela detectada,
  no topo (`y` = topo da tela, dentro da altura da menu bar).
- Clique dentro da pill: chama o mesmo handler que o clique no ícone da menu
  bar usa hoje pra abrir o popover, depois dispensa o painel.

### Fluxo

```
checkThresholdAlert cruza threshold pela 1ª vez
  -> NSSound toca (comportamento atual, mantido)
  -> NotchAlertController.show(percent, label)
       -> sem tela com notch? no-op, sai
       -> cria/reusa NSPanel, seta o SwiftUI content
       -> anima entrada (fade + scale, ~0.3s)
       -> agenda Timer de ~5s
       -> Timer dispara -> anima saída -> panel.close()
  -> se usuário clicar antes do timer: cancela o timer, abre popover, fecha painel
```

Novo trigger só acontece de novo quando o percentual sai do threshold e volta
a cruzar (mesma regra de `lastAlertedPercent` que já existe hoje).

## Casos de borda

- **Sem notch detectado:** no-op silencioso, som+ícone continuam funcionando
  igual hoje.
- **Múltiplos disparos rápidos** (ex: refresh cai o percentual abaixo e sobe
  nas próximas leituras): guarda existente (`lastAlertedPercent`) já evita
  disparo repetido: só reseta quando cai abaixo do threshold.
- **App relançado com painel "preso" na tela** (crash durante exibição): não
  há estado persistido em disco — painel é puramente in-memory, não sobrevive
  a restart, então não há risco de painel "fantasma" ao reabrir o app.
- **Clamshell / notebook fechado com monitor externo:** `NSScreen.screens`
  não vai listar a tela built-in enquanto fechada -> no-op, cai pro
  comportamento atual.

## Fora de escopo (explícito)

- ActivityKit real, Dynamic Island real, app iOS companion.
- Fallback visual pra Macs sem notch.
- Persistir/repetir o alerta se o usuário não estava olhando pra tela.
- Configuração de duração/posição do painel (fixo no código por ora).

## Testes

Sem suite de testes automatizados no projeto (single-file `swiftc` build, sem
Xcode project). Verificação manual:

1. Rodar em MacBook com notch (14"/16" Pro 2021+), ligar `alertsEnabled`,
   forçar percentual acima do `alertThreshold` — confirmar painel aparece,
   some sozinho em ~5s, some com fade suave.
2. Clicar no painel durante os ~5s — confirmar que abre o popover e fecha o
   painel.
3. Rodar em Mac sem notch (ou monitor externo) — confirmar que só o
   som+ícone disparam, sem crash, sem painel órfão.
4. Deixar percentual oscilar acima/abaixo do threshold repetidas vezes —
   confirmar que painel só reaparece a cada nova travessia, não a cada
   refresh.
