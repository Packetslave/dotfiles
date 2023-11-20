;; -*- mode: emacs-lisp -*-
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Brian's emacs config
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Backup and temporary files

(setq backup-directory-alist
      `((".*" . ,temporary-file-directory)))
(setq auto-save-file-name-transforms
      `((".*" ,temporary-file-directory t)))

(setq backup-directory-alist
      `((".*" . ,temporary-file-directory)))
(setq auto-save-file-name-transforms
      `((".*" ,temporary-file-directory t)))

;; (message "Deleting old backup files...")
;; (let ((week (* 60 60 24 7))
;;       (current (float-time (current-time))))
;;   (dolist (file (directory-files temporary-file-directory t))
;;     (when (and (backup-file-name-p file)
;;                (> (- current (float-time (fifth (file-attributes file))))
;;                   week))
;;       (message "%s" file)
;;       (delete-file file))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; STRAIGHT package manager

(setq package-enable-at-startup nil)

(defvar bootstrap-version)
(let ((bootstrap-file
       (expand-file-name "straight/repos/straight.el/bootstrap.el" user-emacs-directory))
      (bootstrap-version 5))
  (unless (file-exists-p bootstrap-file)
    (with-current-buffer
        (url-retrieve-synchronously
         "https://raw.githubusercontent.com/raxod502/straight.el/develop/install.el"
         'silent 'inhibit-cookies)
      (goto-char (point-max))
      (eval-print-last-sexp)))
  (load bootstrap-file nil 'nomessage))

;; Set exec path from the shell's PATH
(straight-use-package 'exec-path-from-shell)
(exec-path-from-shell-initialize)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; THEME

(setq leuven-scale-outline-headlines nil)
(setq leuven-scale-org-agenda-structure nil)
(setq leuven-scale-volatile-highlight nil)

(straight-use-package 'leuven-theme)
(load-theme 'leuven t)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; SELECTRUM narrowing

;; (straight-use-package 'prescient)
;; (straight-use-package 'selectrum-prescient)
;; (straight-use-package 'selectrum)

;; (selectrum-mode +1)
;; (selectrum-prescient-mode +1)
;; (prescient-persist-mode +1)

;; (defun recentf-open-files+ ()
;;   "Use `completing-read' to open a recent file."
;;   (interactive)
;;   (let ((files (mapcar 'abbreviate-file-name recentf-list)))
;;     (find-file (completing-read "Find recent file: " files nil t))))

;; (define-key global-map "\C-x\C-r" 'recentf-open-files+)

(straight-use-package '(ido-vertical-mode :source melpa))
(ido-mode 1)
(ido-everywhere)
(ido-vertical-mode 1)
(setq ido-vertical-define-keys 'C-n-and-C-p-only)
(setq ido-enable-flex-matching t)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; ORG MODE

;(setq org-directory (format "%s/tmp/_docs/org" bl:dropbox))

;; custom colors for Org TODO states
(setq org-todo-keyword-faces
      '(("PRJ" . (:background "DarkGray" :foreground "white"))
	("WAIT" . (:background "Gray" :foreground "white"))
	("DROP" . (:background "Gray" :foreground "black"))))

;; Fontify DONE org todo items
(setq org-fontify-done-headline t)

;; Org mode keybindings
(define-key global-map "\C-ca" 'org-agenda)
(define-key global-map "\C-cl" 'org-store-link)
(define-key global-map "\C-cc" 'org-capture)
(define-key global-map "\C-c\M-s" 'org-save-all-org-buffers)

(setq org-log-done t)
;(setq org-agenda-files
;      (directory-files-recursively
;       (format "%s/tmp/_docs/org" bl:dropbox) "\\.org$"))

(setq org-enforce-todo-dependencies t)
(setq org-agenda-dim-blocked-tasks 'invisble)

(setq org-todo-keywords
      '((sequence "TODO" "WAIT" "|" "DROP" "DONE")))

(setq org-tag-alist '(("today" . ?t) ("errands" . ?e) ("home" . ?h)))
(setq org-startup-folded 'content)

;(defun bl:get-journal-file-today ()
;    (format "%s/journal.org" org-directory))

(setq org-agenda-todo-ignore-scheduled 'future)
(setq org-agenda-tags-todo-honor-ignore-options t)

;(setq org-capture-templates `(
;    ;; ...
;    ("j" "Journal Note"
;         entry (file ,(bl:get-journal-file-today))
;         "* %T: %?\n\n  %i"
;         :empty-lines 1)
;    ;; ..
;    ))

(defun org-archive-done-tasks ()
  (interactive)
  (org-map-entries
   (lambda ()
     (org-archive-subtree)
     (setq org-map-continue-from (org-element-property :begin (org-element-at-point))))
   "/DONE" 'file))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; MAGIT

(straight-use-package 'magit)
(global-set-key "\C-xg" 'magit-status)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; RANDOM STUFF

;(setq load-path (add-to-list
;		 'load-path (format "%s/Library/emacs-wiki-2.7.2" bl:dropbox)))
;(require 'emacs-wiki)

(straight-use-package 'yaml-mode)
(straight-use-package 'crux)

(line-number-mode +1)
(column-number-mode +1)

(straight-use-package 'which-key)
(which-key-mode)

(straight-use-package 'avy)
(global-set-key (kbd "C-:") 'avy-goto-char)

;; Auto-revert files that have changed
(setq global-auto-revert-mode t)

;; alt-x to ctrl-x ctrl-m
(global-set-key "\C-x\C-m" 'execute-extended-command)
(global-set-key "\C-c\C-m" 'execute-extended-command)

;; make ctrl-w delete previous word
(global-set-key "\C-w" 'backward-kill-word)
(global-set-key "\C-x\C-k" 'kill-region)
(global-set-key "\C-c\C-k" 'kill-region)

;; easier top/bottom (esp. on OSX)
(global-set-key "\M-." 'end-of-buffer)
(global-set-key "\M-," 'beginning-of-buffer)

;; kill the chrome
(if (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
(if (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(if (fboundp 'menu-bar-mode) (menu-bar-mode -1))

;; default window (frame) size
(add-to-list 'default-frame-alist '(height . 56))
(add-to-list 'default-frame-alist '(width . 100))

(straight-use-package 'easy-hugo)
(setq easy-hugo-basedir "~/src/packetslave/")

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; CUSTOM

(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(column-number-mode t)
 '(menu-bar-mode nil)
 '(tool-bar-mode nil))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(default ((t (:family "PragmataPro Mono" :foundry "outline" :slant normal :weight normal :height 141 :width normal)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; MAC-SPECIFIC

(if (eq system-type 'darwin)
    (progn
      ;(set-face-attribute 'default nil :height (+ 121 121))
      (setq mac-option-key-is-meta nil)
      (setq mac-command-key-is-meta t)
      (setq mac-command-modifier 'meta)
      (setq mac-option-modifier nil)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; WINDOWS-SPECIFIC

(if (eq system-type 'windows-nt)
    (progn
      (set-face-attribute 'default nil :height (+ 65 65))))

