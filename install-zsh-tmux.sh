#!/usr/bin/env bash
# Installs the current Oh My Zsh/Powerlevel10k and Oh My Tmux setup on a new machine.
set -Eeuo pipefail

readonly MANAGED_MARKER='# Managed by env-init/install-zsh-tmux.sh'

DRY_RUN=0
SKIP_PACKAGES=0
SKIP_SHELL_CHANGE=0

usage() {
  cat <<'USAGE'
Usage: ./install-zsh-tmux.sh [options]

Install Zsh, tmux, Oh My Zsh, Powerlevel10k, Oh My Tmux, and the current
configuration. Supported platforms are Debian-family Linux, Arch Linux, and
macOS.

Options:
  --dry-run            Print all changes without making them.
  --skip-packages      Do not invoke apt, pacman, or Homebrew.
  --skip-shell-change  Do not set zsh as the login shell.
  -h, --help           Show this help.
USAGE
}

info() {
  printf '%s\n' "==> $*"
}

fail() {
  printf '%s\n' "Error: $*" >&2
  exit 1
}

run() {
  if (( DRY_RUN )); then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

run_privileged() {
  if (( EUID == 0 )); then
    run "$@"
  else
    require_command sudo
    run sudo "$@"
  fi
}

detect_platform() {
  case "$(uname -s)" in
    Darwin)
      PLATFORM=macos
      ;;
    Linux)
      local os_release=${ENV_INIT_OS_RELEASE_FILE:-/etc/os-release}
      [[ -r $os_release ]] || fail "Cannot read Linux distribution metadata: $os_release"

      # shellcheck disable=SC1090
      . "$os_release"
      case " ${ID:-} ${ID_LIKE:-} " in
        *' debian '*|*' ubuntu '*)
          PLATFORM=debian
          ;;
        *' arch '*|*' archlinux '*)
          PLATFORM=archlinux
          ;;
        *)
          fail "Unsupported Linux distribution (ID=${ID:-unknown}, ID_LIKE=${ID_LIKE:-unknown})"
          ;;
      esac
      ;;
    *)
      fail "Unsupported operating system: $(uname -s)"
      ;;
  esac
}

install_homebrew() {
  if (( DRY_RUN )); then
    info '[dry-run] Install Homebrew from https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh'
    return
  fi

  info 'Installing Homebrew'
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

install_packages() {
  if (( SKIP_PACKAGES )); then
    info 'Skipping operating-system package installation'
    return
  fi

  case $PLATFORM in
    debian)
      info 'Installing packages with apt'
      run_privileged apt-get update
      run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install --yes zsh tmux git curl perl
      ;;
    archlinux)
      info 'Installing packages with pacman'
      run_privileged pacman -Syu --needed --noconfirm zsh tmux git curl perl
      ;;
    macos)
      local brew
      if brew=$(command -v brew 2>/dev/null); then
        :
      elif [[ -x /opt/homebrew/bin/brew ]]; then
        brew=/opt/homebrew/bin/brew
      elif [[ -x /usr/local/bin/brew ]]; then
        brew=/usr/local/bin/brew
      else
        install_homebrew
        if (( DRY_RUN )); then
          brew=brew
        elif [[ -x /opt/homebrew/bin/brew ]]; then
          brew=/opt/homebrew/bin/brew
        elif [[ -x /usr/local/bin/brew ]]; then
          brew=/usr/local/bin/brew
        else
          fail 'Homebrew installation completed without a usable brew executable'
        fi
      fi

      info 'Installing packages with Homebrew'
      run "$brew" install zsh tmux git perl
      ;;
  esac
}

clone_repository() {
  local url=$1
  local destination=$2

  if [[ -e $destination ]]; then
    [[ -d $destination/.git ]] || fail "Refusing to overwrite non-Git path: $destination"
    info "Keeping existing repository: $destination"
    return
  fi

  info "Cloning $url"
  run git clone --depth=1 "$url" "$destination"
}

backup_unmanaged_file() {
  local path=$1

  if [[ ! -e $path && ! -L $path ]]; then
    return
  fi

  if [[ -f $path ]] && grep -Fq "$MANAGED_MARKER" "$path"; then
    return
  fi

  local backup="${path}.backup.${BACKUP_SUFFIX}"
  info "Backing up $path to $backup"
  run mv "$path" "$backup"
}

write_zshrc() {
  local target=$HOME/.zshrc
  backup_unmanaged_file "$target"

  if (( DRY_RUN )); then
    info "[dry-run] Write $target"
    return
  fi

  cat >"$target" <<'ZSHRC'
# Managed by env-init/install-zsh-tmux.sh
# Powerlevel10k must initialize before code that can write to the terminal.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

export PATH="$HOME/.local/bin:$PATH"
export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(
  git
  sudo
  extract
  colored-man-pages
  history-substring-search
  zsh-autosuggestions
  zsh-syntax-highlighting
)

source "$ZSH/oh-my-zsh.sh"
[[ -r "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"
ZSHRC
}

write_p10k_config() {
  local target=$HOME/.p10k.zsh
  local template=$ZSH_DIR/custom/themes/powerlevel10k/config/p10k-lean.zsh
  backup_unmanaged_file "$target"

  if (( DRY_RUN )); then
    info "[dry-run] Generate $target from $template"
    return
  fi

  [[ -r $template ]] || fail "Powerlevel10k template is missing: $template"
  awk '
    BEGIN {
      print "# Managed by env-init/install-zsh-tmux.sh"
      print "# Current Powerlevel10k wizard choices: compatible, unicode, lean, 1 line, compact, concise, transient prompt."
    }
    /^    # =========================\[ Line #[12] \]=========================$/ { next }
    /^    newline(                 # \\n)?$/ { next }
    /^  typeset -g POWERLEVEL9K_MODE=nerdfont-complete$/ {
      print "  typeset -g POWERLEVEL9K_MODE=compatible"; next
    }
    /^  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true$/ {
      print "  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=false"; next
    }
    /^  typeset -g POWERLEVEL9K_RULER_FOREGROUND=240$/ {
      print "  typeset -g POWERLEVEL9K_RULER_FOREGROUND=242"; next
    }
    /^    typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_FOREGROUND=240$/ {
      print "    typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_GAP_FOREGROUND=242"; next
    }
    /^  # typeset -g POWERLEVEL9K_LOCK_ICON=\x27⭐\x27$/ {
      print "  typeset -g POWERLEVEL9K_LOCK_ICON=\x27∅\x27"; next
    }
    /^  # typeset -g POWERLEVEL9K_DIR_CLASSES=\(\)$/ {
      print "  typeset -g POWERLEVEL9K_DIR_CLASSES=()"; next
    }
    /^  # typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_EXPANSION=\x27⭐\x27$/ {
      print "  typeset -g POWERLEVEL9K_VCS_VISUAL_IDENTIFIER_EXPANSION="; next
    }
    /^  typeset -g POWERLEVEL9K_STATUS_ERROR(_SIGNAL|_PIPE)?_VISUAL_IDENTIFIER_EXPANSION=\x27✘\x27$/ {
      sub(/\x27✘\x27$/, "\x27х\x27"); print; next
    }
    /^  # typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_VISUAL_IDENTIFIER_EXPANSION=\x27⭐\x27$/ {
      print "  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_VISUAL_IDENTIFIER_EXPANSION="; next
    }
    /^  # typeset -g POWERLEVEL9K_BACKGROUND_JOBS_VISUAL_IDENTIFIER_EXPANSION=\x27⭐\x27$/ {
      print "  typeset -g POWERLEVEL9K_BACKGROUND_JOBS_VISUAL_IDENTIFIER_EXPANSION=\x27≡\x27"; next
    }
    /^  # typeset -g POWERLEVEL9K_NORDVPN_VISUAL_IDENTIFIER_EXPANSION=\x27⭐\x27$/ {
      print "  typeset -g POWERLEVEL9K_NORDVPN_VISUAL_IDENTIFIER_EXPANSION=\x27nord\x27"; next
    }
    /^  # typeset -g POWERLEVEL9K_RANGER_VISUAL_IDENTIFIER_EXPANSION=\x27⭐\x27$/ ||
    /^  # typeset -g POWERLEVEL9K_YAZI_VISUAL_IDENTIFIER_EXPANSION=\x27⭐\x27$/ {
      sub(/^  # /, "  "); sub(/\x27⭐\x27$/, "\x27▲\x27"); print; next
    }
    /^  # typeset -g POWERLEVEL9K_KUBECONTEXT_DEFAULT_VISUAL_IDENTIFIER_EXPANSION=\x27⭐\x27$/ {
      print "  typeset -g POWERLEVEL9K_KUBECONTEXT_DEFAULT_VISUAL_IDENTIFIER_EXPANSION=\x27○\x27"; next
    }
    /^  # typeset -g POWERLEVEL9K_AWS_EB_ENV_VISUAL_IDENTIFIER_EXPANSION=\x27⭐\x27$/ {
      print "  typeset -g POWERLEVEL9K_AWS_EB_ENV_VISUAL_IDENTIFIER_EXPANSION=\x27eb\x27"; next
    }
    /^  # typeset -g POWERLEVEL9K_TIME_VISUAL_IDENTIFIER_EXPANSION=\x27⭐\x27$/ {
      print "  typeset -g POWERLEVEL9K_TIME_VISUAL_IDENTIFIER_EXPANSION="; next
    }
    /^  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=off$/ {
      print "  typeset -g POWERLEVEL9K_TRANSIENT_PROMPT=always"; next
    }
    { print }
  ' "$template" >"$target"
}

write_tmux_local_config() {
  local target=$HOME/.tmux.conf.local
  local template=$TMUX_DIR/.tmux.conf.local
  backup_unmanaged_file "$target"

  if (( DRY_RUN )); then
    info "[dry-run] Generate $target from $template"
    return
  fi

  [[ -r $template ]] || fail "Oh My Tmux template is missing: $template"
  awk '
    BEGIN { print "# Managed by env-init/install-zsh-tmux.sh" }
    /^tmux_conf_copy_to_os_clipboard=false$/ {
      print
      print "set -s set-clipboard on"
      next
    }
    /^#set -g mouse on$/ {
      print "set -g mouse on"
      next
    }
    { print }
  ' "$template" >"$target"
}

link_tmux_config() {
  local link=$HOME/.tmux.conf
  local target=$TMUX_DIR/.tmux.conf

  if [[ -L $link && $(readlink "$link") == "$target" ]]; then
    return
  fi

  backup_unmanaged_file "$link"
  run ln -s "$target" "$link"
}

set_login_shell() {
  (( SKIP_SHELL_CHANGE )) && return

  local zsh_path
  zsh_path=$(command -v zsh)
  if [[ ${SHELL:-} != "$zsh_path" ]]; then
    info "Setting the login shell to $zsh_path"
    run chsh -s "$zsh_path"
  fi
}

while (($#)); do
  case $1 in
    --dry-run)
      DRY_RUN=1
      ;;
    --skip-packages)
      SKIP_PACKAGES=1
      ;;
    --skip-shell-change)
      SKIP_SHELL_CHANGE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
  shift
done

(( EUID != 0 )) || fail 'Run this script as the target login user, not as root.'

BACKUP_SUFFIX=$(date +%Y%m%d%H%M%S)
ZSH_DIR=$HOME/.oh-my-zsh
TMUX_DIR=$HOME/.tmux

detect_platform
info "Detected platform: $PLATFORM"
install_packages

require_command git
require_command zsh
require_command tmux
require_command awk

clone_repository https://github.com/ohmyzsh/ohmyzsh.git "$ZSH_DIR"
clone_repository https://github.com/romkatv/powerlevel10k.git "$ZSH_DIR/custom/themes/powerlevel10k"
clone_repository https://github.com/zsh-users/zsh-autosuggestions.git "$ZSH_DIR/custom/plugins/zsh-autosuggestions"
clone_repository https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_DIR/custom/plugins/zsh-syntax-highlighting"
clone_repository https://github.com/gpakosz/.tmux.git "$TMUX_DIR"

write_zshrc
write_p10k_config
write_tmux_local_config
link_tmux_config
set_login_shell

info 'Configuration complete. Start a new terminal, or run: exec zsh'
