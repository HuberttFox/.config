export LANG=en_US.UTF-8

# Keep duplicate commands from piling up in history.
setopt HIST_IGNORE_ALL_DUPS

# Use emacs-style editing by default.
bindkey -e

# Treat path separators as word boundaries.
WORDCHARS=${WORDCHARS//[\/]}

# Let autosuggestions skip expensive rebinding on every prompt.
ZSH_AUTOSUGGEST_MANUAL_REBIND=1
