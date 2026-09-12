;;; agent-shell-usage.el --- Claude/Codex subscription usage in agent-shell mode-line -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;;
;; Author: generated for local use
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, ai
;;
;; This file displays Claude Code and Codex subscription rate-limit usage in
;; agent-shell buffers.  It does NOT use ANTHROPIC_API_KEY or OPENAI_API_KEY.
;;
;; Claude:
;;   Requires wakamex/ccusage in PATH:
;;       uv tool install ccusage
;;   `ccusage json` reads the Claude Code OAuth subscription credentials.
;;
;; Codex:
;;   Requires `codex` in PATH and an existing ChatGPT login.
;;   Uses the local `codex app-server` JSON-RPC method:
;;       account/rateLimits/read
;;
;; Usage:
;;   (add-to-list 'load-path "/path/to/this/file")
;;   (require 'agent-shell-usage)
;;   (agent-shell-usage-mode 1)
;;
;; Optional:
;;   (setq agent-shell-usage-refresh-interval 120)
;;   (setq agent-shell-usage-display-as 'remaining) ; or 'used
;;   (setq agent-shell-usage-show-reset t)
;;
;; Commands:
;;   M-x agent-shell-usage-refresh
;;   M-x agent-shell-usage-show-details

;;; Code:

(require 'json)
(require 'subr-x)

(defgroup agent-shell-usage nil
  "Subscription usage display for coding agents."
  :group 'tools)

(defcustom agent-shell-usage-refresh-interval 120
  "Seconds between usage refreshes.
Both providers are refreshed asynchronously."
  :type 'integer
  :group 'agent-shell-usage)

(defcustom agent-shell-usage-display-as 'remaining
  "Whether percentages in the mode-line mean `remaining' or `used'."
  :type '(choice (const remaining) (const used))
  :group 'agent-shell-usage)

(defcustom agent-shell-usage-show-reset t
  "If non-nil, show compact time-to-reset after each percentage."
  :type 'boolean
  :group 'agent-shell-usage)

(defcustom agent-shell-usage-claude-command "ccusage"
  "Executable used to fetch Claude subscription usage."
  :type 'string
  :group 'agent-shell-usage)

(defcustom agent-shell-usage-codex-command "codex"
  "Codex CLI executable."
  :type 'string
  :group 'agent-shell-usage)

(defcustom agent-shell-usage-separator " | "
  "Separator between Claude and Codex usage."
  :type 'string
  :group 'agent-shell-usage)

(defvar agent-shell-usage--timer nil)
(defvar agent-shell-usage--claude nil)
(defvar agent-shell-usage--codex nil)
(defvar agent-shell-usage--claude-error nil)
(defvar agent-shell-usage--codex-error nil)
(defvar agent-shell-usage--last-refresh nil)
(defvar-local agent-shell-usage--installed-in-buffer nil)

(defun agent-shell-usage--jget (obj key)
  "Get KEY from JSON object OBJ parsed as an alist."
  (when (listp obj)
    (alist-get key obj)))

(defun agent-shell-usage--parse-json (text)
  (json-parse-string text
                     :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object nil))

(defun agent-shell-usage--iso-to-time (iso)
  (when (and iso (stringp iso))
    (condition-case nil
        (date-to-time iso)
      (error nil))))

(defun agent-shell-usage--epoch-to-time (epoch)
  (when (numberp epoch)
    (seconds-to-time epoch)))

(defun agent-shell-usage--time-left (time)
  "Return compact duration from now until TIME."
  (when time
    (let ((seconds (max 0 (floor (float-time (time-subtract time (current-time)))))))
      (cond
       ((>= seconds 86400)
        (let ((days (/ seconds 86400))
              (hours (/ (% seconds 86400) 3600)))
          (if (> hours 0) (format "%dd%dh" days hours) (format "%dd" days))))
       ((>= seconds 3600)
        (format "%dh%02d" (/ seconds 3600) (/ (% seconds 3600) 60)))
       (t
        (format "%dm" (/ seconds 60)))))))

(defun agent-shell-usage--shown-percent (used)
  (when (numberp used)
    (round
     (if (eq agent-shell-usage-display-as 'remaining)
         (- 100 used)
       used))))

(defun agent-shell-usage--face-for-used (used)
  ;; Use standard semantic faces, not hard-coded colors.
  (cond ((not (numberp used)) 'shadow)
        ((>= used 90) 'error)
        ((>= used 70) 'warning)
        (t 'success)))

(defun agent-shell-usage--pct-string (used)
  (if (numberp used)
      (propertize (format "%d%%" (agent-shell-usage--shown-percent used))
                  'face (agent-shell-usage--face-for-used used))
    (propertize "?" 'face 'shadow)))

(defun agent-shell-usage--bucket-string (label bucket)
  (if (not bucket)
      (format "%s:?" label)
    (let* ((used (plist-get bucket :used))
           (reset (plist-get bucket :reset))
           (reset-str (and agent-shell-usage-show-reset
                           (agent-shell-usage--time-left reset))))
      (concat label ":" (agent-shell-usage--pct-string used)
              (if reset-str (concat "↻" reset-str) "")))))

(defun agent-shell-usage--claude-parse (text)
  "Parse `ccusage json` output TEXT."
  (let* ((obj (agent-shell-usage--parse-json text))
         ;; Current ccusage uses `session`; older cache versions used `5h`.
         (session (or (agent-shell-usage--jget obj 'session)
                      (agent-shell-usage--jget obj '5h)))
         (week (agent-shell-usage--jget obj '7d)))
    (list
     :plan (agent-shell-usage--jget obj 'plan)
     :session (when session
                (list :used (agent-shell-usage--jget session 'pct)
                      :reset (agent-shell-usage--iso-to-time
                              (agent-shell-usage--jget session 'resets_at))))
     :week (when week
             (list :used (agent-shell-usage--jget week 'pct)
                   :reset (agent-shell-usage--iso-to-time
                           (agent-shell-usage--jget week 'resets_at))))
     :updated (agent-shell-usage--jget obj 'updated_at))))

(defun agent-shell-usage--refresh-claude ()
  (if-let ((exe (executable-find agent-shell-usage-claude-command)))
      (let ((buf (generate-new-buffer " *agent-shell-usage-claude*")))
        (make-process
         :name "agent-shell-usage-claude"
         :buffer buf
         :command (list exe "json")
         :noquery t
         :connection-type 'pipe
         :sentinel
         (lambda (proc _event)
           (when (memq (process-status proc) '(exit signal))
             (unwind-protect
                 (if (= (process-exit-status proc) 0)
                     (condition-case err
                         (progn
                           (setq agent-shell-usage--claude
                                 (agent-shell-usage--claude-parse
                                  (with-current-buffer (process-buffer proc)
                                    (buffer-string))))
                           (setq agent-shell-usage--claude-error nil))
                       (error
                        (setq agent-shell-usage--claude-error
                              (format "parse: %s" (error-message-string err)))))
                   (setq agent-shell-usage--claude-error
                         (string-trim
                          (with-current-buffer (process-buffer proc)
                            (buffer-string)))))
               (when (buffer-live-p (process-buffer proc))
                 (kill-buffer (process-buffer proc)))
               (force-mode-line-update t))))))
    (setq agent-shell-usage--claude-error
          (format "%s not found" agent-shell-usage-claude-command))))

(defun agent-shell-usage--codex-classify-window (window)
  "Convert a Codex WINDOW to (LABEL . PLIST), using its duration."
  (when window
    (let* ((mins (agent-shell-usage--jget window 'windowDurationMins))
           (used (agent-shell-usage--jget window 'usedPercent))
           (reset (agent-shell-usage--epoch-to-time
                   (agent-shell-usage--jget window 'resetsAt)))
           (label (cond ((equal mins 300) "5h")
                        ((equal mins 10080) "7d")
                        ((numberp mins) (format "%dm" mins))
                        (t "?"))))
      (cons label (list :used used :reset reset :minutes mins)))))

(defun agent-shell-usage--codex-parse-result (result)
  "Parse RESULT from account/rateLimits/read."
  (let* ((limits (agent-shell-usage--jget result 'rateLimits))
         (p (agent-shell-usage--codex-classify-window
             (agent-shell-usage--jget limits 'primary)))
         (s (agent-shell-usage--codex-classify-window
             (agent-shell-usage--jget limits 'secondary)))
         (windows (delq nil (list p s))))
    (list :plan (agent-shell-usage--jget limits 'planType)
          :windows windows
          :five (cdr (assoc "5h" windows))
          :week (cdr (assoc "7d" windows)))))

(defun agent-shell-usage--refresh-codex ()
  "Fetch Codex quota via the local official app-server protocol."
  (if-let ((exe (executable-find agent-shell-usage-codex-command)))
      (let* ((buf (generate-new-buffer " *agent-shell-usage-codex*"))
             (state (list :initialized nil :requested nil :done nil))
             (proc
              (make-process
               :name "agent-shell-usage-codex"
               :buffer buf
               :command (list exe "app-server")
               :coding 'utf-8-unix
               :connection-type 'pipe
               :noquery t
               :filter
               (lambda (p chunk)
                 ;; App-server is line-delimited JSON.  Preserve partial lines.
                 (let ((pending (concat (or (process-get p 'pending) "") chunk))
                       complete)
                   (while (string-match "\\`\\([^\n]*\\)\n" pending)
                     (push (match-string 1 pending) complete)
                     (setq pending (substring pending (match-end 0))))
                   (process-put p 'pending pending)
                   (dolist (line (nreverse complete))
                     (unless (string-empty-p line)
                       (condition-case nil
                           (let* ((msg (agent-shell-usage--parse-json line))
                                  (id (agent-shell-usage--jget msg 'id))
                                  (result (agent-shell-usage--jget msg 'result)))
                             (cond
                              ((and (equal id 1) result
                                    (not (plist-get state :requested)))
                               (setq state (plist-put state :initialized t))
                               ;; Complete the standard app-server handshake.
                               (process-send-string
                                p
                                (concat
                                 (json-serialize
                                  '((jsonrpc . "2.0")
                                    (method . "initialized")
                                    (params . nil)))
                                 "\n"))
                               (setq state (plist-put state :requested t))
                               (process-send-string
                                p
                                (concat
                                 (json-serialize
                                  '((jsonrpc . "2.0")
                                    (id . 2)
                                    (method . "account/rateLimits/read")
                                    (params . nil)))
                                 "\n")))
                              ((and (equal id 2) result)
                               (setq agent-shell-usage--codex
                                     (agent-shell-usage--codex-parse-result result))
                               (setq agent-shell-usage--codex-error nil)
                               (setq state (plist-put state :done t))
                               (delete-process p)
                               (force-mode-line-update t))
                              ((and (equal id 2) (agent-shell-usage--jget msg 'error))
                               (setq agent-shell-usage--codex-error
                                     (format "%S" (agent-shell-usage--jget msg 'error)))
                               (setq state (plist-put state :done t))
                               (delete-process p)
                               (force-mode-line-update t))))
                         (error nil))))))
               :sentinel
               (lambda (p _event)
                 (when (memq (process-status p) '(exit signal))
                   (unless (plist-get state :done)
                     (setq agent-shell-usage--codex-error
                           (string-trim
                            (with-current-buffer (process-buffer p)
                              (buffer-string)))))
                   (when (buffer-live-p (process-buffer p))
                     (kill-buffer (process-buffer p)))
                   (force-mode-line-update t))))))
        ;; Initialize app-server.  experimentalApi is harmless on versions that
        ;; no longer require it and helps compatibility with older versions.
        (process-send-string
         proc
         (concat
          (json-serialize
           '((jsonrpc . "2.0")
             (id . 1)
             (method . "initialize")
             (params .
                     ((clientInfo . ((name . "emacs-agent-shell-usage")
                                     (version . "1.0")))
                      (capabilities . ((experimentalApi . t)))))))
          "\n")))
    (setq agent-shell-usage--codex-error
          (format "%s not found" agent-shell-usage-codex-command))))

;;;###autoload
(defun agent-shell-usage-refresh ()
  "Refresh Claude and Codex subscription quotas asynchronously."
  (interactive)
  (setq agent-shell-usage--last-refresh (current-time))
  (agent-shell-usage--refresh-claude)
  (agent-shell-usage--refresh-codex))

(defun agent-shell-usage--provider-tooltip (name data error)
  (cond
   (error (format "%s usage unavailable: %s\nMouse-1: refresh" name error))
   ((not data) (format "%s usage: waiting for first refresh\nMouse-1: refresh" name))
   (t
    (let ((plan (or (plist-get data :plan) "?")))
      (format "%s (%s)\nDisplay: %s percentage\nMouse-1: refresh; Mouse-2: details"
              name plan agent-shell-usage-display-as)))))

(defun agent-shell-usage--claude-string ()
  (if agent-shell-usage--claude
      (let ((s (agent-shell-usage--bucket-string
                "S" (plist-get agent-shell-usage--claude :session)))
            (w (agent-shell-usage--bucket-string
                "W" (plist-get agent-shell-usage--claude :week))))
        (concat "C " s " " w))
    (propertize "C ?" 'face 'shadow)))

(defun agent-shell-usage--codex-string ()
  (if agent-shell-usage--codex
      (let ((five (plist-get agent-shell-usage--codex :five))
            (week (plist-get agent-shell-usage--codex :week))
            (windows (plist-get agent-shell-usage--codex :windows)))
        ;; If Codex changes its quotas, show every returned window rather than
        ;; silently pretending primary=5h and secondary=7d.
        (concat "X "
                (if (or five week)
                    (string-join
                     (delq nil
                           (list (and five (agent-shell-usage--bucket-string "5h" five))
                                 (and week (agent-shell-usage--bucket-string "7d" week))))
                     " ")
                  (string-join
                   (mapcar (lambda (x)
                             (agent-shell-usage--bucket-string (car x) (cdr x)))
                           windows)
                   " "))))
    (propertize "X ?" 'face 'shadow)))

(defvar agent-shell-usage--mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1]
                (lambda (_event) (interactive) (agent-shell-usage-refresh)))
    (define-key map [mode-line mouse-2]
                (lambda (_event) (interactive) (agent-shell-usage-show-details)))
    map))

(defun agent-shell-usage--mode-line ()
  "Return cached usage text for the mode-line."
  (let* ((c (propertize
             (agent-shell-usage--claude-string)
             'help-echo (agent-shell-usage--provider-tooltip
                         "Claude" agent-shell-usage--claude agent-shell-usage--claude-error)
             'mouse-face 'mode-line-highlight
             'local-map agent-shell-usage--mode-line-map))
         (x (propertize
             (agent-shell-usage--codex-string)
             'help-echo (agent-shell-usage--provider-tooltip
                         "Codex" agent-shell-usage--codex agent-shell-usage--codex-error)
             'mouse-face 'mode-line-highlight
             'local-map agent-shell-usage--mode-line-map)))
    (concat " " c agent-shell-usage-separator x " ")))

(defun agent-shell-usage--install-here ()
  "Add the usage segment to the current agent-shell buffer."
  (unless agent-shell-usage--installed-in-buffer
    (setq-local agent-shell-usage--installed-in-buffer t)
    ;; `mode-line-format-right-align` is built into modern Emacs.  It inserts
    ;; flexible space so our segment naturally occupies the unused right side.
    (setq-local mode-line-format
                (append mode-line-format
                        '(mode-line-format-right-align
                          (:eval (agent-shell-usage--mode-line)))))))

(defun agent-shell-usage-show-details ()
  "Show the latest cached provider details."
  (interactive)
  (with-help-window "*Agent usage*"
    (princ (format "Percentages shown in mode-line: %s\n\n"
                   agent-shell-usage-display-as))
    (princ "Claude\n")
    (if agent-shell-usage--claude
        (pp agent-shell-usage--claude)
      (princ (format "  unavailable%s\n"
                     (if agent-shell-usage--claude-error
                         (concat ": " agent-shell-usage--claude-error) ""))))
    (princ "\nCodex\n")
    (if agent-shell-usage--codex
        (pp agent-shell-usage--codex)
      (princ (format "  unavailable%s\n"
                     (if agent-shell-usage--codex-error
                         (concat ": " agent-shell-usage--codex-error) ""))))
    (when agent-shell-usage--last-refresh
      (princ (format "\nLast refresh started: %s\n"
                     (format-time-string "%Y-%m-%d %H:%M:%S"
                                         agent-shell-usage--last-refresh))))))

(defun agent-shell-usage--start-timer ()
  (when (timerp agent-shell-usage--timer)
    (cancel-timer agent-shell-usage--timer))
  (setq agent-shell-usage--timer
        (run-at-time 0 agent-shell-usage-refresh-interval #'agent-shell-usage-refresh)))

(defun agent-shell-usage--stop-timer ()
  (when (timerp agent-shell-usage--timer)
    (cancel-timer agent-shell-usage--timer))
  (setq agent-shell-usage--timer nil))

;;;###autoload
(define-minor-mode agent-shell-usage-mode
  "Globally maintain subscription usage and display it in agent-shell buffers."
  :global t
  :group 'agent-shell-usage
  (if agent-shell-usage-mode
      (progn
        (add-hook 'agent-shell-mode-hook #'agent-shell-usage--install-here)
        ;; Install immediately in already-existing agent-shell buffers.
        (dolist (buf (buffer-list))
          (with-current-buffer buf
            (when (derived-mode-p 'agent-shell-mode)
              (agent-shell-usage--install-here))))
        (agent-shell-usage--start-timer))
    (remove-hook 'agent-shell-mode-hook #'agent-shell-usage--install-here)
    (agent-shell-usage--stop-timer)))

(provide 'agent-shell-usage)

;;; agent-shell-usage.el ends here
