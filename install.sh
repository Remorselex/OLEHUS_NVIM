#!/usr/bin/env bash
# Разворачивает конфиги из этого репозитория. Идемпотентен: можно гонять повторно.
# Всё, что лежало на месте ссылки, сначала уезжает в бэкап с отметкой времени.
set -euo pipefail

DOTFILES_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BACKUP_DIR="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
LAZYGIT_DIR="$HOME/Library/Application Support/lazygit"

link() {
  local source=$1 target=$2
  mkdir -p "$(dirname "$target")"
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
    printf '  уже связано  %s\n' "${target/#$HOME/~}"
    return
  fi
  if [ -e "$target" ] || [ -L "$target" ]; then
    mkdir -p "$BACKUP_DIR"
    mv "$target" "$BACKUP_DIR/$(basename "$target")"
    printf '  бэкап       %s → %s\n' "${target/#$HOME/~}" "${BACKUP_DIR/#$HOME/~}"
  fi
  ln -s "$source" "$target"
  printf '  связано     %s\n' "${target/#$HOME/~}"
}

echo "1/5 пакеты Homebrew"
if command -v brew >/dev/null; then
  brew bundle --file="$DOTFILES_DIR/Brewfile"
else
  echo "  brew не найден: https://brew.sh — поставь и запусти скрипт заново" >&2
  exit 1
fi

echo "2/5 oh-my-zsh и его плагины"
[ -d "$HOME/.oh-my-zsh" ] || sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
ZSH_PLUGINS="$HOME/.oh-my-zsh/custom/plugins"
[ -d "$ZSH_PLUGINS/zsh-autosuggestions" ] || git clone -q https://github.com/zsh-users/zsh-autosuggestions "$ZSH_PLUGINS/zsh-autosuggestions"
[ -d "$ZSH_PLUGINS/zsh-syntax-highlighting" ] || git clone -q https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH_PLUGINS/zsh-syntax-highlighting"

echo "3/5 tree-sitter CLI (в brew-пакете его нет, нужен для сборки парсеров)"
command -v tree-sitter >/dev/null || npm install -g tree-sitter-cli

echo "4/5 симлинки"
link "$DOTFILES_DIR/nvim"                 "$HOME/.config/nvim"
link "$DOTFILES_DIR/ghostty/config"       "$HOME/.config/ghostty/config"
link "$DOTFILES_DIR/starship/starship.toml" "$HOME/.config/starship.toml"
link "$DOTFILES_DIR/lazygit/config.yml"   "$LAZYGIT_DIR/config.yml"
link "$DOTFILES_DIR/zsh/zshrc"            "$HOME/.zshrc"
link "$DOTFILES_DIR/git/ignore"           "$HOME/.config/git/ignore"

if [ ! -f "$HOME/.zshrc.local" ]; then
  cp "$DOTFILES_DIR/zsh/zshrc.local.example" "$HOME/.zshrc.local"
  chmod 600 "$HOME/.zshrc.local"
  echo "  создан ~/.zshrc.local — впиши туда свои токены и пути"
fi

echo "5/5 git-алиасы"
if ! git config --global --get-all include.path | grep -qx "$DOTFILES_DIR/git/aliases.gitconfig"; then
  git config --global --add include.path "$DOTFILES_DIR/git/aliases.gitconfig"
fi
echo "  подключено; user.name и user.email задай себе сам:"
echo "    git config --global user.name  \"Имя Фамилия\""
echo "    git config --global user.email \"you@example.com\""

cat <<'DONE'

Готово. Дальше:
  1. открой новый Ghostty (или source ~/.zshrc)
  2. запусти nvim — lazy.nvim поставит плагины ровно тех версий, что в lazy-lock.json
  3. :checkhealth  — проверить, что всё нашлось
  4. helpmevim     — шпаргалка по всему этому хозяйству
DONE
