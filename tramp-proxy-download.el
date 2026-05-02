;;; tramp-proxy-download.el --- Download command handlers for tramp-proxy  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: tramp-proxy developers
;; Keywords: processes, tools

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Wget and curl command handlers for tramp-proxy.
;; Handles remote execution and result syncing for file downloads.

;;; Code:

(require 'tramp-proxy-utils)
(require 'tramp-proxy)
(require 'url-parse)

;;; Wget Handler

(defun tramp-proxy--extract-wget-output (args)
  "Extract output filename from wget ARGS.
Returns the filename specified by -O or --output-document, or nil."
  (let ((output nil)
        (skip-next nil))
    (dolist (arg args)
      (cond
       (skip-next
        (setq output arg)
        (setq skip-next nil))
       ((or (string= arg "-O") (string= arg "--output-document"))
        (setq skip-next t))
       ;; Handle -Ofilename (no space)
       ((string-match-p "^-O" arg)
        (setq output (substring arg 2)))))
    output))

(defun tramp-proxy--wget-default-filename (url)
  "Determine default filename for wget download of URL.
Uses the last path component of the URL."
  (let ((parsed (url-generic-parse-url url)))
    (file-name-nondirectory (url-filename parsed))))

(defun tramp-proxy--extract-wget-urls (args)
  "Extract URL(s) from wget ARGS.
Returns a list of URLs found in the argument list."
  (let ((urls '())
        (skip-next nil))
    (dolist (arg args)
      (cond
       (skip-next
        (setq skip-next nil))
       ;; Skip options and their values
       ((string-match-p "^-" arg)
        (when (member arg '("-O" "--output-document"
                            "-P" "--directory-prefix"
                            "-U" "--user-agent"
                            "--post-file" "--header"
                            "--load-cookies" "--save-cookies"))
          (setq skip-next t))
        ;; Handle -Ovalue form (e.g., -Ofilename) — no action needed here
        )
       ;; Non-option args are URLs
       (t
        (push arg urls))))
    (nreverse urls)))

(defun tramp-proxy--handle-wget (_command args)
  "Handle wget via remote proxy.
_COMMAND is ignored (always \"wget\"). ARGS is the argument list."
  (let* ((urls (tramp-proxy--extract-wget-urls args))
         (output-file (tramp-proxy--extract-wget-output args))
         (local-dir (expand-file-name default-directory))
         (remote-dir (tramp-proxy--local-to-remote local-dir)))
    (unless urls
      (error "tramp-proxy: could not determine URL from wget arguments"))
    ;; Build args with forced progress
    (let ((wget-args (append
                      (list "--progress=bar:force")
                      ;; Remove any existing progress options to avoid conflicts
                      (cl-remove-if (lambda (a)
                                      (string-match-p "--progress" a))
                                    args))))
      (tramp-proxy--execute-with-term
       remote-dir
       "wget" wget-args
       (lambda (status local-dir remote-dir exit-code)
         (pcase status
           ('success
            (message "tramp-proxy: syncing wget results from remote...")
            (let ((results (if output-file
                               (list output-file)
                             (mapcar #'tramp-proxy--wget-default-filename urls))))
              (dolist (file results)
                (let ((remote-file (concat remote-dir "/" file))
                      (local-file (expand-file-name file local-dir)))
                  (when (file-exists-p remote-file)
                    (tramp-proxy--copy-file remote-file local-file)))))
            (message "tramp-proxy: wget complete"))
           ('error
            (message "tramp-proxy: wget failed with code %s" exit-code))
           ('interrupted
            (message "tramp-proxy: wget interrupted"))))))))

;;; Curl Handler

(defun tramp-proxy--extract-curl-output (args)
  "Extract output filename from curl ARGS.
Returns a cons cell (TYPE . FILENAME) where TYPE is `explicit',
`remote-name', or nil."
  (let ((output nil)
        (type nil)
        (skip-next nil))
    (dolist (arg args)
      (cond
       (skip-next
        (setq output arg)
        (setq type 'explicit)
        (setq skip-next nil))
       ((or (string= arg "-o") (string= arg "--output"))
        (setq skip-next t))
       ((or (string= arg "-O") (string= arg "--remote-name"))
        (setq type 'remote-name))
       ;; Handle -ofilename (no space)
       ((and (string-match-p "^-o" arg) (not (string= arg "-o")))
        (setq output (substring arg 2))
        (setq type 'explicit))))
    (if output
        (cons type output)
      (if type
          (cons type nil)
        nil))))

(defun tramp-proxy--curl-default-filename (url)
  "Determine default filename for curl download of URL.
Uses the last path component of the URL."
  (let ((parsed (url-generic-parse-url url)))
    (file-name-nondirectory (url-filename parsed))))

(defun tramp-proxy--extract-curl-urls (args)
  "Extract URL(s) from curl ARGS.
Returns a list of URLs found in the argument list."
  (let ((urls '())
        (skip-next nil))
    (dolist (arg args)
      (cond
       (skip-next
        (setq skip-next nil))
       ;; Skip options and their values
       ((string-match-p "^-" arg)
        (when (member arg '("-o" "--output"
                            "-T" "--upload-file"
                            "-u" "--user"
                            "-H" "--header"
                            "-e" "--referer"
                            "-b" "--cookie"
                            "-c" "--cookie-jar"
                            "-F" "--form"
                            "-d" "--data"
                            "--data-binary" "--data-urlencode"
                            "--json"))
          (setq skip-next t))
        ;; Handle -ovalue form (e.g., -ofilename) — no action needed here
        )
       ;; Non-option args are URLs
       (t
        (push arg urls))))
    (nreverse urls)))

(defun tramp-proxy--handle-curl (_command args)
  "Handle curl via remote proxy.
_COMMAND is ignored (always \"curl\"). ARGS is the argument list."
  (let* ((urls (tramp-proxy--extract-curl-urls args))
         (output (tramp-proxy--extract-curl-output args))
         (local-dir (expand-file-name default-directory))
         (remote-dir (tramp-proxy--local-to-remote local-dir)))
    (unless urls
      (error "tramp-proxy: could not determine URL from curl arguments"))
    ;; If no output option given, default to -O (remote name)
    ;; This ensures we have files to sync back
    (let ((curl-args (if output
                         args
                       (append args (list "-O")))))
      ;; Force progress bar
      (unless (cl-some (lambda (a) (member a '("-#" "--progress-bar" "-s" "--silent" "-q")))
                       curl-args)
        (setq curl-args (cons "-#" curl-args)))
      (tramp-proxy--execute-with-term
       remote-dir
       "curl" curl-args
       (lambda (status local-dir remote-dir exit-code)
         (pcase status
           ('success
            (message "tramp-proxy: syncing curl results from remote...")
            (let ((results (pcase (car output)
                             (`explicit
                              (list (cdr output)))
                             (`remote-name
                              (mapcar #'tramp-proxy--curl-default-filename urls))
                             (_
                              ;; We added -O above
                              (mapcar #'tramp-proxy--curl-default-filename urls)))))
              (dolist (file results)
                (let ((remote-file (concat remote-dir "/" file))
                      (local-file (expand-file-name file local-dir)))
                  (when (file-exists-p remote-file)
                    (tramp-proxy--copy-file remote-file local-file)))))
            (message "tramp-proxy: curl complete"))
           ('error
            (message "tramp-proxy: curl failed with code %s" exit-code))
           ('interrupted
            (message "tramp-proxy: curl interrupted"))))))))

(provide 'tramp-proxy-download)
;;; tramp-proxy-download.el ends here
