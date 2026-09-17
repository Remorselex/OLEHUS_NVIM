# dotfiles

Терминальная среда разработки под macOS: Neovim вместо IDE, git целиком в терминале.

## Установка

```bash
git clone <url-этого-репозитория> ~/dotfiles
~/dotfiles/install.sh
```

Скрипт идемпотентен. Всё, что лежало на месте будущего симлинка, уезжает в
`~/.dotfiles-backup/<дата>/` — ничего не затирается молча.

## Что ставится

| | |
|---|---|
| **Ghostty** | терминал: прозрачность, сплиты, quick terminal на `Cmd+\`` |
| **Neovim + LazyVim** | 57 плагинов, версии зафиксированы в `nvim/lazy-lock.json` |
| **Neogit** | порт Magit: статус, попапы, коммит в обычном буфере |
| **lazygit** | быстрый просмотр, custom patch (`Ctrl+P`), worktree |
| **diffview** | диффы и разрешение конфликтов в три колонки |
| **delta / difftastic** | построчный и структурный диффы |
| **starship** | промпт: путь, worktree, ветка, статус |
| **eza / bat / fzf / zoxide / ripgrep / fd** | замена базовым утилитам |

## Раскладка

```
nvim/                 → ~/.config/nvim
ghostty/config        → ~/.config/ghostty/config
starship/starship.toml→ ~/.config/starship.toml
lazygit/config.yml    → ~/Library/Application Support/lazygit/config.yml
zsh/zshrc             → ~/.zshrc
git/aliases.gitconfig → подключается через include.path
```

Это симлинки: правишь у себя — правишь репозиторий, `git diff` сразу видит.

## Секреты сюда не кладём

Токены, рабочие URL и `JAVA_HOME` живут в `~/.zshrc.local` — файл вне репозитория,
`zsh/zshrc` подхватывает его в конце, если он есть. Шаблон — `zsh/zshrc.local.example`.

`user.name` и `user.email` для git тоже не в репозитории: их задаёт каждый себе.

## Свой код

Помимо чужих плагинов здесь есть свои модули в `nvim/lua/util/`:

| | |
|---|---|
| `theme.lua` | тема запоминается на проект (ключ — корень git) |
| `syntax-contrast.lua` | различение групп синтаксиса начертанием, а не только цветом |
| `git-patch.lua` | патчи как файлы: `format-patch`, применение с `--check` |
| `lualine-accent.lua` | акцент статуслайна берётся из палитры активной темы |

## Шпаргалка

```bash
helpmevim
```

Десять разделов: старт, основы Vim, навигация, LSP, git, терминал и запуск,
окружение проектов, Ghostty и шелл, переход с CLion, FAQ.
