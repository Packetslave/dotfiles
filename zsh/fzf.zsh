# Setup fzf
# ---------
if [[ ! "$PATH" == */Users/blanders/.fzf/bin* ]]; then
  export PATH="${PATH:+${PATH}:}/Users/blanders/.fzf/bin"
fi

# Auto-completion
# ---------------
[[ $- == *i* ]] && source "/Users/blanders/.fzf/shell/completion.zsh" 2> /dev/null

# Key bindings
# ------------
source "/Users/blanders/.fzf/shell/key-bindings.zsh"
