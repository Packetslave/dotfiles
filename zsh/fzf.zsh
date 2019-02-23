# Setup fzf
# ---------
if [[ ! "$PATH" == */home/blanders/.fzf/bin* ]]; then
  export PATH="$PATH:/home/blanders/.fzf/bin"
fi

# Auto-completion
# ---------------
[[ $- == *i* ]] && source "/home/blanders/.fzf/shell/completion.zsh" 2> /dev/null

# Key bindings
# ------------
source "/home/blanders/.fzf/shell/key-bindings.zsh"

