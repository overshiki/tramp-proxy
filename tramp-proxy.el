;;; tramp-proxy.el --- TRAMP remote command proxy for eshell  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: tramp-proxy developers
;; Keywords: processes, tools

;; This file is not part of GNU Emacs.

;;; Commentary:

;; This package provides `tramp-proxy-mode', a minor mode for eshell
;; that transparently intercepts download commands and executes them
;; on a remote server via TRAMP, syncing results back to the local
;; filesystem.
;;
;; Supported commands:
;;   - git clone
;;   - wget
;;   - curl
;;
;; Usage:
;;   (require 'tramp-proxy)
;;   (setq tramp-proxy-host "my-server")
;;   M-x tramp-proxy-mode  ; in eshell buffer
;;
;; Or use explicit commands:
;;   $ proxy-git clone https://github.com/user/repo.git
;;   $ proxy-wget https://example.com/file.zip
;;   $ proxy-curl -O https://example.com/file.zip

;;; Code:

(require 'term)
(require 'tramp)
(require 'ansi-color)
(require 'tramp-proxy-utils)

;; Forward declare eshell functions
(autoload 'eshell-named-command "esh-cmd")

(defvar tramp-proxy--command-registry
  '("git" "wget" "curl")
  "List of command names that tramp-proxy will intercept.")

(defvar tramp-proxy--active-processes nil
  "List of active remote proxy processes.
Each element is an alist with keys: process, local-dir, remote-dir,
command, args, callback.")

(defvar-local tramp-proxy--local-dir nil
  "Local directory associated with the current proxy process.")

(defvar-local tramp-proxy--remote-dir nil
  "Remote directory associated with the current proxy process.")

(defvar-local tramp-proxy--command nil
  "Command name for the current proxy process.")

(defvar-local tramp-proxy--callback nil
  "Callback function for the current proxy process.")

(defvar-local tramp-proxy--status nil
  "Completion status for the current proxy process.")

(defvar-local tramp-proxy--exit-code nil
  "Exit code for the current proxy process.")

(defun tramp-proxy--active-p ()
  "Return non-nil if tramp-proxy is properly configured."
  (and tramp-proxy-host
       (not (string-empty-p tramp-proxy-host))))

(defun tramp-proxy--parse-command (command)
  "Parse an eshell COMMAND string into (NAME . ARGS) list.
Returns nil if parsing fails."
  (condition-case nil
      (let* ((split (split-string-and-unquote command))
             (name (car split))
             (args (cdr split)))
        (cons name args))
    (error nil)))

(defun tramp-proxy--command-supported-p (command-name)
  "Return t if COMMAND-NAME is in the proxy registry."
  (not (null (member command-name tramp-proxy--command-registry))))

(defun tramp-proxy--get-handler (command-name)
  "Return the handler function for COMMAND-NAME."
  (pcase command-name
    ("git" #'tramp-proxy--handle-git)
    ("wget" #'tramp-proxy--handle-wget)
    ("curl" #'tramp-proxy--handle-curl)
    (_ nil)))

(defun tramp-proxy--fallback-local (command args)
  "Execute COMMAND with ARGS locally as fallback."
  (message "tramp-proxy: falling back to local execution of %s" command)
  (apply #'eshell-named-command command args))

;;;###autoload
(define-minor-mode tramp-proxy-mode
  "Toggle TRAMP proxy mode in eshell.
When enabled, supported commands (git, wget, curl) are executed on
a remote host via TRAMP and results are synced back."
  :lighter " TRAMP-P"
  (unless (derived-mode-p 'eshell-mode)
    (setq tramp-proxy-mode nil)
    (error "tramp-proxy-mode can only be enabled in eshell"))
  (if tramp-proxy-mode
      (advice-add 'eshell-named-command :around
                  #'tramp-proxy--around-eshell-named-command)
    (advice-remove 'eshell-named-command
                   #'tramp-proxy--around-eshell-named-command)))

(defun tramp-proxy--around-eshell-named-command (orig-fun command &optional args)
  "Around-advice for `eshell-named-command'.
If COMMAND is a supported proxy command and `tramp-proxy-mode' is active,
execute it remotely. Otherwise call ORIG-FUN."
  (if (and tramp-proxy-mode
           (tramp-proxy--active-p)
           (tramp-proxy--command-supported-p command))
      (let ((handler (tramp-proxy--get-handler command)))
        (if handler
            (condition-case err
                (funcall handler command args)
              (error
               (message "tramp-proxy error: %s" (error-message-string err))
               (if tramp-proxy-fallback-on-error
                   (funcall orig-fun command args)
                 (signal (car err) (cdr err)))))
          (funcall orig-fun command args)))
    (funcall orig-fun command args)))

;;; Process Filter

(defun tramp-proxy--process-filter (proc string)
  "Process filter that handles \\r progress bars cleanly.
Replaces \\r with \\r\\e[K so `term-emulate-terminal' clears the line,
preventing leftover characters when progress text shortens."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((inhibit-read-only t)
            (moving (= (point) (process-mark proc))))
        (save-excursion
          (goto-char (process-mark proc))
          ;; Replace \r (not followed by \n) with \r\e[K to clear line
          (let ((modified
                 (replace-regexp-in-string
                  "\r\([^\n]\|\'\)" "\r\e[K\1" string)))
            (term-emulate-terminal proc modified))
          (set-marker (process-mark proc) (point)))
        (if moving (goto-char (process-mark proc)))))))




(defvar tramp-proxy-buffer-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "C-c C-k") #'tramp-proxy--interrupt-process)
    (define-key map (kbd "C-c C-c") #'tramp-proxy--interrupt-process)
    map)
  "Keymap for tramp-proxy display buffers.
C-c C-k and C-c C-c interrupt the remote process.")

(defun tramp-proxy--interrupt-process ()
  "Interrupt the current tramp-proxy process.
Bound in proxy display buffers."
  (interactive)
  (let ((proc (get-buffer-process (current-buffer))))
    (when proc
      (interrupt-process proc)
      (message "tramp-proxy: interrupted remote process"))))

;;; Core Execution Engine

(defun tramp-proxy--make-buffer-name (command args)
  "Generate a unique buffer name for COMMAND with ARGS."
  (let ((arg-str (mapconcat #'identity args " ")))
    (if (string-empty-p arg-str)
        (format "*tramp-proxy:%s*" command)
      (format "*tramp-proxy:%s %s*" command
              (truncate-string-to-width arg-str 40 nil nil "…")))))

(defun tramp-proxy--execute-with-term (remote-dir command args &optional callback)
  "Execute COMMAND with ARGS in REMOTE-DIR using term-mode for display.
Optional CALLBACK is called with (status local-dir remote-dir result) when done.
STATUS is one of: success, error, interrupted.
Returns the process object."
  (let* ((local-dir (expand-file-name default-directory))  ;; Capture before rebind
         (default-directory remote-dir)
         (buf-name (tramp-proxy--make-buffer-name command args))
         (buf (get-buffer-create buf-name))
         (process-connection-type t)  ;; Force PTY allocation
         (cmd-list (tramp-proxy--unbuffered-args command args)))
    ;; Ensure remote directory exists
    (tramp-proxy--ensure-remote-directory remote-dir)
    ;; Setup display buffer
    (with-current-buffer buf
      (term-mode)
      (term-line-mode)
      (setq buffer-read-only nil)
      (erase-buffer)
      (setq-local tramp-proxy--local-dir local-dir)
      (setq-local tramp-proxy--remote-dir remote-dir)
      (setq-local tramp-proxy--command command)
      (setq-local tramp-proxy--callback callback))
    ;; Start process remotely via TRAMP
    (message "tramp-proxy: starting %s on %s..." command tramp-proxy-host)
    (let ((proc (apply #'start-file-process
                       "tramp-proxy" buf
                       (car cmd-list) (cdr cmd-list))))
      ;; Store process metadata
      (setq tramp-proxy--active-processes
            (cons (list (cons 'process proc)
                        (cons 'local-dir local-dir)
                        (cons 'remote-dir remote-dir)
                        (cons 'command command)
                        (cons 'args args)
                        (cons 'callback callback))
                  tramp-proxy--active-processes))
      ;; Setup process filter for terminal emulation
      (set-process-filter proc #'term-emulate-terminal)
      ;; Setup sentinel for completion handling
      (set-process-sentinel proc #'tramp-proxy--process-sentinel)
      ;; Display buffer
      (display-buffer buf '(display-buffer-pop-up-window))
      proc)))

(defun tramp-proxy--process-sentinel (proc event)
  "Process sentinel for tramp-proxy processes.
Handles completion, errors, and result syncing."
  (when (or (string-match-p "finished" event)
            (string-match-p "exited abnormally" event)
            (string-match-p "killed" event)
            (string-match-p "interrupt" event))
    ;; Remove from active list
    (setq tramp-proxy--active-processes
          (cl-remove-if (lambda (entry)
                          (eq (cdr (assq 'process entry)) proc))
                        tramp-proxy--active-processes))
    ;; Get metadata from buffer-local variables
    (let* ((buf (process-buffer proc))
           (status (cond
                    ((string-match-p "finished" event) 'success)
                    ((string-match-p "interrupt" event) 'interrupted)
                    (t 'error)))
           (exit-code (when (string-match "exited abnormally with code \([0-9]+\)" event)
                        (string-to-number (match-string 1 event))))
           callback local-dir remote-dir command)
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (setq-local tramp-proxy--status status)
          (setq-local tramp-proxy--exit-code exit-code)
          (setq callback tramp-proxy--callback)
          (setq local-dir tramp-proxy--local-dir)
          (setq remote-dir tramp-proxy--remote-dir)
          (setq command tramp-proxy--command)))
      ;; Handle completion
      (pcase status
        ('success
         (message "tramp-proxy: %s completed. Syncing results..." command)
         (when callback
           (funcall callback status local-dir remote-dir nil)))
        ('interrupted
         (message "tramp-proxy: %s interrupted by user." command)
         (when callback
           (funcall callback status local-dir remote-dir nil)))
        ('error
         (message "tramp-proxy: %s failed with code %s" command (or exit-code "unknown"))
         (when callback
           (funcall callback status local-dir remote-dir exit-code))))
      ;; Cleanup remote on success only
      (when (eq status 'success)
        (tramp-proxy--cleanup-remote remote-dir)))))

;;; Explicit eshell commands

(defun eshell/proxy-git (&rest args)
  "Run git remotely via TRAMP proxy.
Usage: proxy-git clone <url>"
  (if (tramp-proxy--active-p)
      (tramp-proxy--handle-git "git" args)
    (error "tramp-proxy-host is not set")))

(defun eshell/proxy-wget (&rest args)
  "Run wget remotely via TRAMP proxy.
Usage: proxy-wget <url>"
  (if (tramp-proxy--active-p)
      (tramp-proxy--handle-wget "wget" args)
    (error "tramp-proxy-host is not set")))

(defun eshell/proxy-curl (&rest args)
  "Run curl remotely via TRAMP proxy.
Usage: proxy-curl -O <url>"
  (if (tramp-proxy--active-p)
      (tramp-proxy--handle-curl "curl" args)
    (error "tramp-proxy-host is not set")))

;; Forward declarations for handlers (defined in other files)
(autoload 'tramp-proxy--handle-git "tramp-proxy-git")
(autoload 'tramp-proxy--handle-wget "tramp-proxy-download")
(autoload 'tramp-proxy--handle-curl "tramp-proxy-download")

(provide 'tramp-proxy)

;; Load command handlers
(require 'tramp-proxy-git)
(require 'tramp-proxy-download)

;;; tramp-proxy.el ends here
