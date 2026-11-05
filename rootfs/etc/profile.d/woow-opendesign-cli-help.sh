if [[ $- == *i* ]]; then
  cat <<'HELP'
OpenDesign CLI terminal (logins and CLI settings persist in /app/.od/home)
  Claude Code login: claude                 then run /login if prompted
  Codex login:       codex login --device-auth
  Pi setup/login:    pi                     then use /login in the TUI
  OpenCode providers: use OpenDesign Settings > API providers, or run opencode auth login
HELP
fi
