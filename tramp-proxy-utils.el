;;; tramp-proxy-utils.el --- Utility functions for tramp-proxy  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: tramp-proxy developers
;; Keywords: processes, tools

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Path encoding, file synchronization helpers, and remote detection
;; utilities for tramp-proxy.

;;; Code:

(require 'tramp)

(defgroup tramp-proxy nil
  "TRAMP remote command proxy."
  :group 'eshell
  :group 'tramp)

(defcustom tramp-proxy-host nil
  "Remote host to use for proxy execution.
Must be a host recognized by TRAMP (e.g., from ~/.ssh/config)."
  :type '(choice (const :tag "None" nil)
                 string)
  :group 'tramp-proxy)

(defcustom tramp-proxy-remote-root "/tmp/tramp-proxy"
  "Base directory on remote for proxy working directories."
  :type 'string
  :group 'tramp-proxy)

(defcustom tramp-proxy-cleanup-remote t
  "If non-nil, delete remote working directory after successful sync."
  :type 'boolean
  :group 'tramp-proxy)

(defcustom tramp-proxy-transfer-method 'tramp
  "Method for pulling results: `tramp' or `rsync'."
  :type '(choice (const :tag "TRAMP" tramp)
                 (const :tag "rsync" rsync))
  :group 'tramp-proxy)

(defcustom tramp-proxy-fallback-on-error t
  "If non-nil, execute command locally when remote proxy fails."
  :type 'boolean
  :group 'tramp-proxy)

(defcustom tramp-proxy-sync-context-files
  '("~/.gitconfig")
  "List of local files to push to remote before git commands.
Paths can use `~' expansion."
  :type '(repeat string)
  :group 'tramp-proxy)

(defun tramp-proxy--encode-path (path)
  "Encode local PATH into a remote-safe directory name.
Replaces directory separators and special characters with underscores.
Handles Windows drive letters (e.g., C:\\foo -> C_foo)."
  (let* ((expanded (expand-file-name path))
         ;; Handle Windows drive letters like C:
         (no-colon (replace-regexp-in-string
                    "\\([A-Za-z]\\):\\\\"
                    "\\1_"
                    expanded))
         ;; Replace remaining separators and special chars
         (encoded (replace-regexp-in-string
                   "[/\\\\:@]"
                   "_"
                   no-colon)))
    ;; Collapse multiple underscores
    (replace-regexp-in-string "_+" "_" encoded)))

(defun tramp-proxy--local-to-remote (local-dir)
  "Map LOCAL-DIR to a remote path under `tramp-proxy-remote-root'."
  (unless tramp-proxy-host
    (error "tramp-proxy-host is not set"))
  (let ((encoded (tramp-proxy--encode-path local-dir)))
    (concat "/ssh:" tramp-proxy-host ":"
            tramp-proxy-remote-root "/" encoded)))

(defun tramp-proxy--remote-executable-p (executable)
  "Check if EXECUTABLE exists on the remote host."
  (unless tramp-proxy-host
    (error "tramp-proxy-host is not set"))
  (let ((remote-path (concat "/ssh:" tramp-proxy-host ":/usr/bin/" executable))
        result)
    (condition-case nil
        (setq result (file-executable-p remote-path))
      (error nil))
    (unless result
      (condition-case nil
          (setq result (file-executable-p
                        (concat "/ssh:" tramp-proxy-host ":/bin/" executable)))
        (error nil)))
    result))

(defun tramp-proxy--copy-file-if-exists (local-path remote-path)
  "Copy LOCAL-PATH to REMOTE-PATH if LOCAL-PATH exists.
REMOTE-PATH should be a TRAMP path."
  (let ((expanded (expand-file-name local-path)))
    (when (file-exists-p expanded)
      (condition-case err
          (copy-file expanded remote-path t)
        (error (message "tramp-proxy: failed to copy %s: %s"
                        expanded err))))))

(defun tramp-proxy--copy-file (source dest)
  "Copy file from SOURCE to DEST, using configured transfer method.
Both paths may be TRAMP paths."
  (if (eq tramp-proxy-transfer-method 'rsync)
      (tramp-proxy--copy-file-rsync source dest)
    (copy-file source dest t)))

(defun tramp-proxy--copy-file-rsync (source dest)
  "Copy file from SOURCE to DEST using rsync."
  (let* ((default-directory (expand-file-name "~"))
         (source-local (if (tramp-tramp-file-p source)
                           (tramp-file-name-localname
                            (tramp-dissect-file-name source))
                         source))
         (dest-local (if (tramp-tramp-file-p dest)
                         (tramp-file-name-localname
                          (tramp-dissect-file-name dest))
                       dest))
         (host (when (tramp-tramp-file-p source)
                 (tramp-file-name-host
                  (tramp-dissect-file-name source))))
         (dest-host (when (tramp-tramp-file-p dest)
                      (tramp-file-name-host
                       (tramp-dissect-file-name dest)))))
    (cond
     ;; Remote to local
     (host
      (shell-command
       (format "rsync -a %s:%s %s" host source-local dest-local)))
     ;; Local to remote
     (dest-host
      (shell-command
       (format "rsync -a %s %s:%s" source-local dest-host dest-local)))
     ;; Local to local (shouldn't happen, but handle gracefully)
     (t
      (copy-file source dest t)))))

(defun tramp-proxy--ensure-remote-directory (remote-dir)
  "Ensure REMOTE-DIR exists on the remote host.
REMOTE-DIR should be a TRAMP path."
  (make-directory remote-dir t))

(defun tramp-proxy--sync-to-remote (_local-dir remote-dir command)
  "Push necessary local context to REMOTE-DIR before executing COMMAND.
_LOCAL-DIR is the local working directory (unused)."
  (tramp-proxy--ensure-remote-directory remote-dir)
  (when (string-match-p "^git" command)
    (dolist (file tramp-proxy-sync-context-files)
      (let ((local-file (expand-file-name file))
            (remote-file (concat remote-dir "/"
                                 (file-name-nondirectory
                                  (expand-file-name file)))))
        (tramp-proxy--copy-file-if-exists local-file remote-file)))))

(defun tramp-proxy--sync-from-remote (remote-dir local-dir)
  "Pull all files from REMOTE-DIR to LOCAL-DIR.
Returns list of copied file names."
  (let ((copied '()))
    (condition-case err
        (progn
          ;; Ensure local directory exists
          (make-directory local-dir t)
          ;; List remote files
          (when (file-directory-p remote-dir)
            (dolist (file (directory-files remote-dir nil "^[^.]"))
              (let ((remote-file (concat remote-dir "/" file))
                    (local-file (expand-file-name file local-dir)))
                (if (file-directory-p remote-file)
                    ;; For directories, use recursive copy or rsync
                    (if (eq tramp-proxy-transfer-method 'rsync)
                        (tramp-proxy--copy-file-rsync remote-file local-file)
                      (tramp-proxy--copy-directory remote-file local-file))
                  ;; Single file
                  (tramp-proxy--copy-file remote-file local-file))
                (push file copied)))))
      (error (message "tramp-proxy: sync from remote failed: %s" err)
             (signal (car err) (cdr err))))
    copied))

(defun tramp-proxy--copy-directory (source dest)
  "Copy directory from SOURCE to DEST.
Handles TRAMP paths by falling back to copy-directory."
  (copy-directory source dest t t t))

(defun tramp-proxy--cleanup-remote (remote-dir)
  "Delete REMOTE-DIR if `tramp-proxy-cleanup-remote' is non-nil."
  (when (and tramp-proxy-cleanup-remote
             (file-directory-p remote-dir))
    (condition-case err
        (delete-directory remote-dir t)
      (error (message "tramp-proxy: failed to cleanup %s: %s"
                      remote-dir err)))))

(defun tramp-proxy--unbuffered-args (command args)
  "Wrap COMMAND and ARGS with stdbuf if available remotely.
Returns a list suitable for `start-file-process'."
  (if (tramp-proxy--remote-executable-p "stdbuf")
      (append (list "stdbuf" "-o0" "-e0")
              (list command)
              args)
    (cons command args)))

(provide 'tramp-proxy-utils)
;;; tramp-proxy-utils.el ends here
