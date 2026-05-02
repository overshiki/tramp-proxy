;;; tramp-proxy-git.el --- Git command handler for tramp-proxy  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: tramp-proxy developers
;; Keywords: processes, tools

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Git command handler for tramp-proxy.
;; Currently supports `git clone'.

;;; Code:

(require 'tramp-proxy-utils)
(require 'tramp-proxy)

(defun tramp-proxy--extract-git-url-and-target (args)
  "Extract repository URL and target directory from git ARGS.
Returns a cons cell (URL . TARGET-DIR) where TARGET-DIR may be nil.
Handles common git clone options by skipping flags."
  (let ((url nil)
        (target nil)
        (skip-next nil)
        (seen-double-dash nil))
    (dolist (arg args)
      (cond
       (skip-next
        (setq skip-next nil))
       ((string= arg "--")
        (setq seen-double-dash t))
       ;; Skip single-letter options and their values
       ((and (not seen-double-dash)
             (string-match-p "^-" arg))
        ;; Some options take a value
        (when (member arg '("-b" "--branch" "-u" "--upload-pack"
                            "-c" "--config" "-o" "--origin"
                            "-s" "--shared" "--reference"
                            "--separate-git-dir" "-j" "--jobs"
                            "--depth" "--shallow-since"
                            "--shallow-exclude" "--filter"))
          (setq skip-next t)))
       ;; First non-option is URL
       ((not url)
        (setq url arg))
       ;; Second non-option is target
       ((not target)
        (setq target arg))
       ;; Ignore anything else
       (t nil)))
    (cons url target)))

(defun tramp-proxy--handle-git (_command args)
  "Handle git commands via remote proxy.
_COMMAND is the command name (ignored, always \"git\").
ARGS is the list of arguments."
  (let ((subcommand (car args)))
    (pcase subcommand
      ("clone" (tramp-proxy--git-clone args))
      (_ (error "tramp-proxy: git subcommand '%s' not supported. Only 'clone' is supported." subcommand)))))

(defun tramp-proxy--git-clone (args)
  "Execute git clone remotely and sync results back.
ARGS is the argument list after `git clone'."
  (let* ((parsed (tramp-proxy--extract-git-url-and-target (cdr args)))
         (url (car parsed))
         (target (cdr parsed))
         (local-dir (expand-file-name default-directory))
         (remote-dir (tramp-proxy--local-to-remote local-dir)))
    (unless url
      (error "tramp-proxy: could not determine repository URL from git clone arguments"))
    ;; Determine target directory name
    (let* ((target-name (or target
                            (file-name-nondirectory
                             (directory-file-name
                              (replace-regexp-in-string "\\.git$" "" url)))))
           (remote-target-dir (concat remote-dir "/" target-name))
           (local-target-dir (expand-file-name target-name local-dir)))
      ;; Check for local collision
      (when (file-exists-p local-target-dir)
        (error "tramp-proxy: target directory '%s' already exists locally"
               local-target-dir))
      ;; Pre-sync context
      (tramp-proxy--sync-to-remote local-dir remote-dir "git")
      ;; Execute clone with progress
      (let ((clone-args (append (list "clone" "--progress")
                                ;; Remove user's --progress if present to avoid duplicates
                                (cl-remove-if (lambda (a)
                                                (member a '("--progress" "--verbose" "-v")))
                                              (cdr args)))))
        (tramp-proxy--execute-with-term
         remote-dir
         "git" clone-args
         (lambda (status _local-dir _remote-dir exit-code)
           (pcase status
             ('success
              (message "tramp-proxy: syncing cloned repository from remote...")
              (tramp-proxy--sync-from-remote remote-target-dir local-target-dir)
              (message "tramp-proxy: git clone complete: %s" local-target-dir))
             ('error
              (message "tramp-proxy: git clone failed with code %s" exit-code))
             ('interrupted
              (message "tramp-proxy: git clone interrupted")))))))))

(provide 'tramp-proxy-git)
;;; tramp-proxy-git.el ends here
