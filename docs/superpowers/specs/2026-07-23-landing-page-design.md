# Landing page (GitHub Pages)

## Contexto

Projeto não tem página própria — só o README. Pedido: criar uma home page e
publicar via GitHub Pages, com uma URL final voltando pro repo/README.

## Decisões

- **Hospedagem:** GitHub Pages servindo da branch `main`, pasta `/docs`
  (`docs/index.html`). Sem branch `gh-pages` dedicada — Pages moderno não
  precisa disso, e manter tudo em `main` significa que mudanças na página
  passam pelo fluxo normal de commits/PR do resto do repo, sem precisar
  trocar de branch pra editar.
  - Nota: o projeto já usa `docs/superpowers/` pra specs/plans internos
    (este arquivo, por exemplo). Servir Pages de `/docs` torna esses
    markdowns tecnicamente alcançáveis pela URL do Pages — mas o repo já é
    público, então isso não muda o que é ou não acessível, só adiciona mais
    um caminho pro mesmo conteúdo já público. Não é um problema de
    segurança, só uma nota de organização.
- **URL:** domínio padrão do GitHub Pages
  (`djalmaaraujo.github.io/claude-usage-menubar`), sem domínio próprio.
- **Stack:** HTML + CSS puro, um arquivo (`docs/index.html`), zero build
  step, zero framework/dependência — consistente com o resto do projeto
  (app é um único arquivo Swift, zero deps).

## Conteúdo

1. **Hero** — logo (`assets/logo.svg`), tagline, comando de instalação
   Homebrew com botão de copiar (`brew install djalmaaraujo/tap/claude-usage-menubar`).
2. **Zero tokens** — explica que `/usage` é interceptado localmente pela
   CLI, nunca chega no modelo, custo real zero (mesmo fato já documentado
   no CLAUDE.md/README).
3. **Screenshots** — `screenshot-dark.png` e `screenshot-light.png` lado a
   lado, mostrando o popover em ambos os modos.
4. **Instalação** — bloco Homebrew (comando + copiar) e link "build from
   source" apontando pro README.
5. **Requisitos/limitações** — direto, sem meias palavras: macOS 13+, exige
   Claude Code CLI instalado e logado, não roda em Linux/Windows, não é
   serviço hospedado (roda 100% local).
6. **FAQ** (em inglês, sem emoji):
   - "Does it consume tokens to calculate usage?" → No — `/usage` is
     intercepted locally by the CLI, never reaches the model. Zero cost.
   - "Does it work on Linux or Windows?" → No, macOS only (13+).
   - "Does it cost anything?" → Completely free and open source (MIT).
   - "Any plans to support other LLMs?" → No.
7. **Footer** — link pro repo GitHub, licença MIT.

Sem emoji em lugar nenhum da página (pedido explícito).

## Visual

- Fundo escuro navy/indigo (`#0f172a` → `#1e1b4b`, mesmo gradiente do
  `logo.svg`), mantendo o brand atual — não o fundo claro do rams.ai usado
  como referência.
- Princípios de estilo emprestados do rams.ai: muito espaço em branco entre
  seções, hierarquia tipográfica confiante (H1 grande e direto, sem
  enfeite), tom funcionalista — sem elementos decorativos supérfluos, sem
  gradientes/sombras em excesso.
- Acento: gradiente ciano→indigo (`#22d3ee` → `#6366f1`, mesmo do logo),
  usado com parcimônia — botão de instalação, links, poucos destaques
  pontuais. Não pintar a página inteira com o gradiente.
- Texto: slate claro (`#e2e8f0`) pro corpo, slate médio (`#94a3b8`) pra
  texto secundário/legendas — mesma paleta already usada no `logo.svg` e
  nos badges do README.
- Tipografia: monospace (`ui-monospace, SFMono-Regular, Menlo, monospace`),
  mesma família do logo, pra manter identidade "terminal/dev tool" do
  projeto.

## Depois de publicado

- Habilitar GitHub Pages nas configurações do repo (Settings → Pages →
  Source: branch `main`, pasta `/docs`) — mudança de configuração do repo,
  não dá pra fazer só com commit; sinalizar pro usuário confirmar/fazer
  isso se a API não permitir via `gh`.
- Atualizar `README.md` com o link da página publicada (topo, perto do
  badge row).

## Fora de escopo

- Domínio próprio.
- Analytics/tracking de qualquer tipo.
- Múltiplas páginas/seções de navegação — é uma landing de página única.
- Dark/light mode toggle na própria página (fica só no modo escuro do
  brand).
