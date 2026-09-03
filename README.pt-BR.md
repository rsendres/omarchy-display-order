# Omarchy Display Order

Reordene visualmente os monitores do Omarchy e mantenha a disposição lógica e a escala do Hyprland em sincronia.

[🇺🇸 English](README.md) | 🇧🇷 **Português**

## Visão geral

O plugin adiciona numeração e arrastar-e-soltar à seção **Displays** do Omarchy. Ele reordena e identifica somente displays **habilitados e não espelhados**.

```text
Antes                         Depois de arrastar o Monitor 2
1  Monitor 1                  1  Monitor 2
2  Monitor 2                  2  Monitor 1
```

Ao soltar uma linha, a primeira posição vira o monitor lógico mais à esquerda; as demais seguem da esquerda para a direita. O plugin muda a geometria dos displays; não move janelas entre saídas físicas.

### Recursos

- Arrastar-e-soltar para reordenar displays.
- Identificação do monitor físico ao passar o cursor sobre uma linha.
- Posicionamento lógico automático, considerando escala e rotação.
- Escala no monitor em foco.
- Controles de brilho e tamanho do texto.
- Controles para habilitar/desabilitar monitores (o último display ativo não pode ser desabilitado).
- Ordem persistente e restauração segura após recarregamentos.

## Exemplo visual

Arraste uma linha para alterar a ordem lógica da esquerda para a direita:

![Arrastar uma linha de monitor altera a ordem lógica](assets/drag-and-drop-ordering.png)

## Requisitos

- Omarchy 4.0.1-1, com seu sistema de plugins e os comandos `omarchy plugin`.
- Hyprland 0.56.2.
- `hyprctl`, `jq`, `flock` e `luac` (requisitos de execução; `luac` é necessário para validar e atualizar `monitors.lua`).

Estas são as versões usadas no desenvolvimento e na validação. A compatibilidade com outras versões de Omarchy ou Hyprland não foi testada.

## Instalação

Instale pelo mecanismo oficial de plugins do Omarchy:

```bash
omarchy plugin add https://github.com/rsendres/omarchy-display-order.git --enable
```

## Uso

Abra **Setup → Display**. Em **DISPLAYS**, arraste as linhas numeradas até a ordem desejada.

### Identificar um display

Passe o cursor sobre uma linha por dois segundos. O número da linha aparece no canto superior esquerdo do display físico correspondente e permanece visível enquanto o ponteiro estiver sobre a linha. Ele desaparece ao sair; a identificação fica desativada durante o arrastar-e-soltar. O plugin usa o nome da saída do Hyprland, como `DP-2` ou `HDMI-A-1`.

### Escala, brilho e tamanho do texto

- **Scale** atua no monitor em foco e exige uma ordem salva válida em `order.json` e que o monitor em foco esteja habilitado e não espelhado.
- As predefinições de escala são reduzidas à unidade válida mais próxima de `1/120`. A interface mostra duas casas decimais; a configuração gerada preserva seis algarismos significativos.
- **Brightness** ajusta o brilho por meio de `omarchy-brightness-display` quando o controle está disponível; a disponibilidade é determinada pelo retorno válido desse comando.
- **Text size** ajusta o tamanho do texto da interface.
- Os controles de habilitar/desabilitar monitor garantem que pelo menos um display permaneça ativo.

### Workspaces

Durante uma reordenação explícita, o plugin pode renumerar temporariamente apenas os workspaces base padrão elegíveis quando o conjunto ativo for exatamente `1..N` **e** seus nomes corresponderem aos padrões. Workspaces nomeados, mistos ou especiais não são renumerados nem gerenciados permanentemente pelo plugin. A alteração não move janelas entre saídas físicas.

```mermaid
flowchart LR
    A[Ordem salva] --> B{Workspaces ativos = 1..N<br/>com nomes padrão?}
    B -- Sim --> C[Renumerar workspaces base]
    B -- Não --> D[Manter workspaces]
    C --> E[Aplicar geometria dos displays]
    D --> E
```

## Persistência e restauração

- `order.json` é a fonte da ordem preferida dos monitores.
- A geometria ao vivo pode usar coordenadas calculadas. As regras persistidas usam `0x0` no primeiro monitor e `auto-right` nos seguintes.
- Na inicialização, a restauração exige uma ordem salva e o contexto de sessão/runtime do Hyprland. Ela roda uma vez por assinatura de sessão do Hyprland; se falhar, não fica tentando indefinidamente nessa sessão.
- Um bloco gerenciado em `monitors.lua` torna os recarregamentos seguros.

## Recuperação e desinstalação

Para remover **somente** o bloco `monitors.lua` gerenciado pelo plugin:

```bash
scripts/reorder-displays --remove-config-block
```

Isso não é uma reversão completa da configuração. `--restore-last` exige um snapshot salvo do layout ao vivo e que o Hyprland esteja acessível, e faz uma tentativa de melhor esforço para restaurá-lo; não oferece recuperação offline.

Ao reescrever `~/.config/hypr/monitors.lua`, o plugin mantém ao lado do arquivo os cinco backups mais recentes, com timestamp, criados por ele. Backups criados por outras ferramentas não são gerenciados.

Depois, remova o plugin pelo Omarchy:

```bash
omarchy plugin remove omarchy-display-order.display-order
```

## Limitações

- O tratamento automático avançado de hotplug ainda não foi implementado.
- A restauração depende de `order.json` e de um contexto de sessão/runtime válido do Hyprland.
- Fora da renumeração temporária de workspaces base padrão elegíveis durante uma reordenação explícita, o plugin não impõe numeração de workspaces, não cria workspaces nem gerencia permanentemente workspaces arbitrários.

## Desenvolvimento

Execute estes checks a partir da raiz do plugin:

```bash
bash -n scripts/reorder-displays
tests/test_reorder_displays.sh
bash tests/test_scale_normalization.sh
luac -p "$HOME/.config/hypr/monitors.lua"
git diff --check
omarchy plugin validate .
```

Se `qmlformat` estiver instalado, formate ou valide os arquivos QML antes de contribuir:

```bash
qmlformat -i Panel.qml Service.qml MonitorIdentifier.qml
```
