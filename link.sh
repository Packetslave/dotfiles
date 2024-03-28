#!/bin/sh

ln -sf ~/dotfiles/zsh/zshrc ~/.zshrc
ln -sf ~/dotfiles/zsh/p10k.zsh ~/.p10k.zsh
ln -sf ~/dotfiles/tmux/tmux.conf ~/.tmux.conf
ln -sf ~/dotfiles/tmux/tmuxline ~/.tmuxline
ln -sf ~/dotfiles/vim/vimrc ~/.vimrc
ln -sf ~/dotfiles/vim/vim ~/.vim

mkdir -p ~/.emacs.d
ln -sf ~/dotfiles/emacs/emacs.d/init.el ~/.emacs.d/init.el

mkdir -p ~/.tmux/plugins
ln -sf ~/dotfiles/tmux/plugins ~/.tmux

rm ~/bin
ln -sf ~/dotfiles/bin ~/bin
