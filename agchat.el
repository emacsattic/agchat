;;; agchat.el --- comint-based emacs interface for chatting on AgChat

;; Copyright (C) 1995, 2002 Noah S. Friedman

;; Author: Noah Friedman <friedman@splode.com>
;; Maintainer: friedman@splode.com
;; Keywords: communication, extensions
;; Status: Works in Emacs 19 and later, and in XEmacs.
;; Created: 1995-01-02

;; $Id: agchat.el,v 1.9 2002/08/04 23:13:29 friedman Exp $

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, you can either send email to this
;; program's maintainer or write to: The Free Software Foundation,
;; Inc.; 59 Temple Place - Suite 330; Boston, MA 02111-1307, USA.

;;; Commentary:

;; AgChat is a chat system written by silver Harloe <silver@silverchat.com>.

;; popup mode is implemented via pb-popup.el; see
;; http://www.splode.com/~friedman/software/emacs-lisp#pb-popup

;;; Code:

(require 'comint)

(or (featurep 'pb-popup)
    (load "pb-popup" t))


(defvar agchat-buffer-name-format "*agchat-%s*"
  "*Basic buffer name for AgChat sessions.
This string is fed to `format' as the format specifier with the host name
of the chat system, as a string.  If you don't wish for the name to appear
in the buffer name, don't include a `%s' in it.
Also, use `%%' to get a single `%' in the buffer name.")

(defvar agchat-host "silverchat.com"
  "*A string specifying the internet name or IP address of the agchat host.")

(defvar agchat-port 23
  "*An integer specifying the TCP port of the agchat server on agchat-host.")

(defvar agchat-mode-hook nil
  "*Hook to run at the end of agchat-mode.")

(defvar agchat-connect-hook nil
  "*Hook to run after establishing a connection to the server.
This is run after agchat-mode-hook and only when initiating a new connection.")

(defvar agchat-output-filter-functions
  '(agchat-default-output-filter agchat-color-filter agchat-popup)
  "Functions to call after output is inserted into the buffer.
These functions get one argument, a string containing the text just inserted.
Also, the buffer is narrowed to the region of the inserted text.

Note that the string received by these functions contain the raw string as
received by the server; they do not reflect any alterations made by filters.

Some possible functions to add are `agchat-popup-window' and
`agchat-default-output-filter'.")

(defvar agchat-open-network-stream-function 'open-network-stream
  "*Function to use to establish client network connection.
This function is called with 4 args: name, buffer, host, and port.
For a description of these args see `open-network-stream' function.")

(defvar agchat-default-output-filter-regexp-list
  '(;; All lines are terminated by a carriage return
    "\C-m"
    ;; strip bells; use a separate filter to beep if desired.
    "\C-g"
    ;; These are telnet handshakes that appears when first connecting.
    "\377\373\C-c"
    "\377\373\C-a"
    ;; This is a "nudge" sent periodically by the server to see if the
    ;; client is still awake; it consists of a space followed by a vt100
    ;; backspace.
    " \e\\[D")
  "*Regular expression identifying substrings to strip from incoming text.
This may consist of characters like carriage returns, backspaces, etc.")

;; Do not change this without changing agchat-color-filter appropriately.
(defconst agchat-color-mode-regexp
  "\e\\[0;3\\([0-9]\\)\\(;1\\)?;4\\([0-9]\\);?m")

(defvar agchat-color-scheme-table
  '((ansi    (0 "black")
             (1 "red")
             (2 "green")
             (3 "yellow")
             (4 "blue")
             (5 "magenta")
             (6 "cyan")
             (7 "white"))

    (x-light (0 "black"         "grey30")
             (1 "red"           "pink")
             (2 "green"         "light green")
             (3 "goldenrod"     "light goldenrod")
             (4 "blue"          "light blue")
             (5 "magenta"       "plum1")
             (6 "cyan"          "light cyan")
             (7 "grey90"        "white"))

    (x-dark  (0 "black"         "darkgrey")
             (1 "darkred"       "red")
             (2 "darkgreen"     "green")
             (3 "darkgoldenrod" "goldenrod")
             (4 "darkblue"      "blue")
             (5 "darkmagenta"   "magenta")
             (6 "darkcyan"      "cyan")
             (7 "dimgrey"       "white")))

  "*Mapping between vt100 color escape sequences and highlight colors.
This table maps the vt100 color escape sequences output by the silverchat
server into the color names documented in the `@command' command.
Unless you don't like the actual colors rendered, don't change this
table; use @command instead to change your preferences.

This variable is an alist of scheme names with a sub-alist of integers and
color values, i.e. each elt of this table is of the form

    (SCHEME (0 COLOR1 BRIGHTCOLOR1)
            (1 COLOR2 BRIGHTCOLOR2)
            ...)

If only one color is specified for an integer, the corresponding \"bright\"
color is implemented by making the color bold.  If a second color is
specified, that color will be used as the \"bright\" alternative.

The actual color scheme used is determined by the value of
`agchat-color-scheme'.")

(defvar agchat-color-scheme 'ansi
  "*Color scheme to use from `agchat-color-scheme-table'.
This value should be a symbol matching one of the defined scheme names.")

(defvar agchat-message-timestamp-format "%H:%M "
  "*Timestamp inserted before messages by `agchat-message-timestamp'.")


;;; Variables only of use if you have pb-popup.el

(defvar agchat-popup-regexp-list
  '("P#[0-9]+:C[^)\n]+)" "\C-g")
  "*List of regular expressions matching events worthy of popup notification.
For any input from the server matching one of these regular expressions,
if the agchat buffer is not presently visible, a new window will be created
displaying it.  See function `agchat-popup-window'.")


;;; These are not user variables

(defconst agchat-colors-need-faces-p
  (or (string-lessp emacs-version "20")
      (save-match-data
        (and (string-match "XEmacs\\|Lucid" (emacs-version)) t))))

;; String literals discarded by `agchat-process-filter' when received.
;; These are exact and case-sensitive.
;; Primarily these are strings which are not displayed and should not be
;; accumulated in the process filter data.
(defvar agchat-process-filter-discard-strings
  '(;; This is a "nudge" sent periodically by the server to see if the
    ;; client is still awake; it consists of a space followed by a vt100
    ;; backspace.
    ;; Long periods of idle time can cause these strings to accumulate and
    ;; waste string storage.
    " \e\\[D"))

;; This variable is used to hold the contents of any data received by the
;; process filter until a double newline is received; that signals the end
;; of the message and it is necessary to make sure the entire line is
;; received for the color filter to work accurately.
(defvar agchat-process-filter-data nil)
(make-variable-buffer-local 'agchat-process-filter-data)


;;;###autoload
(defun agchat (host &optional port &optional newp)
  "Connect to a agchat system.
The user is prompted for the host and port number.
The default for each is inserted in the minibuffer to be edited if desired.

With a prefix argument, always create a new chat session even if there is
already an existing connection to that chat.  Otherwise, try to switch to an
existing session on that host."
  (interactive (list (read-from-minibuffer "agchat host: " agchat-host)
                     (read-from-minibuffer "agchat port: "
                                           (number-to-string agchat-port))
                     current-prefix-arg))
  (and (stringp port)
       (setq port (string-to-number port)))
  (cond ((interactive-p)
         ;; If set and called interactively, change defaults
         (and port (setq agchat-port port))
         (and host (setq agchat-host host))))
  ;; If called from lisp and nil, use defaults
  (or host (setq host agchat-host))
  (or port (setq port agchat-port))

  (let* ((buf-fun (if newp 'generate-new-buffer 'get-buffer-create))
         (buffer (funcall buf-fun (format agchat-buffer-name-format host)))
         (proc (get-buffer-process buffer)))
    (switch-to-buffer buffer)
    (cond
     ((and proc
           (memq (process-status proc) '(run stop open connect))))
     (t
      (goto-char (point-max))
      (setq proc (funcall agchat-open-network-stream-function
                          "agchat" buffer host port))
      (set-process-buffer proc buffer)
      (set-marker (process-mark proc) (point-max))
      (agchat-mode)
      ;; These must be done after calling agchat-mode (which calls
      ;; comint-mode) since that function may set its own process
      ;; filter and sentinel for this process.
      ;; Also, avoid killing local variables set below.
      (set-process-filter proc 'agchat-process-filter)
      (set-process-sentinel proc 'agchat-process-sentinel)
      (cond
       ;; Done for Emacs 19 and later only.
       ((string-lessp "19" emacs-version)
        (agchat-make-local-variables 'kill-buffer-hook 'pre-command-hook)
        (add-hook 'kill-buffer-hook 'agchat-delete-process)
        (add-hook 'pre-command-hook
                  'agchat-goto-eob-on-insert-before-process-mark)))
      (and (memq (process-status proc) '(open run))
           (run-hooks 'agchat-connect-hook))))))

;;;###autoload
(defun agchat-mode ()
  "Major mode for agchat sessions.

If the `comint' library is available, `comint-mode' is called to
implement a command history, etc.  Otherwise, `text-mode' is called.
This means either `comint-mode-hook' or `text-mode-hook' may be run, but
almost certainly not both.

It is best to put agchat mode--specific hooks on `agchat-mode-hook'."
  (interactive)
  (comint-mode)

  (make-local-variable 'comint-prompt-regexp)
  (setq comint-prompt-regexp "^")

  (make-local-variable 'comint-input-sender)
  (setq comint-input-sender 'agchat-simple-send)

  (make-local-variable 'comint-input-filter-functions)
  (add-hook 'comint-input-filter-functions 'agchat-delete-input-region)

  (setq mode-name "agchat")
  (setq major-mode 'agchat-mode)
  (setq mode-line-process '(":%s"))
  (make-local-variable 'case-fold-search)
  (setq case-fold-search t)
  (make-local-variable 'scroll-step)
  (setq scroll-step 1)

  (run-hooks 'agchat-mode-hook))

(defun agchat-process-filter (proc string)
  (cond ((member string agchat-process-filter-discard-strings))
        (t
         (and agchat-process-filter-data
              (setq string (concat agchat-process-filter-data string)
                    agchat-process-filter-data nil))
         (let ((pos 0))
           (save-match-data
             ;; Most messages end with two newlines in succession.
             ;; There are some pathological cases, like @help or /cN, where the
             ;; last line may have color spec (when color enabled) between
             ;; two CR or LF chars, or just two carriage returns followed
             ;; by a linefeed.  These cases are probably bugs.
             (while (string-match "\n\\(\e\\[[0-9;]+m\\)?\n\\|\r\\(\e\\[[0-9;]+m\\)?\r\n"
                                  string pos)
               (setq pos (match-end 0))))
           (cond ((= pos 0)
                  (setq agchat-process-filter-data string)
                  (setq string nil))
                 ((/= pos (length string))
                  (setq agchat-process-filter-data (substring string pos))
                  (setq string (substring string 0 pos)))))
         (and string
              (agchat-display-output proc string)))))

(defun agchat-process-sentinel (proc event)
  (let ((status (process-status proc)))
    (cond ((string= event "open\n")
           ;; If we connected using a non-blocking connect and the
           ;; connection has just been established, run the connect hook
           ;; now.
           (run-hooks 'agchat-connect-hook))
          ((or (eq status 'closed)
               (string-match "exited" event))
           (let ((orig-buffer (current-buffer)))
             (unwind-protect
                 (progn
                   (set-buffer (process-buffer proc))
                   (goto-char (point-max))
                   (insert (format "\n\nProcess %s %s\n" proc event)))
               (set-buffer orig-buffer)))
           (agchat-delete-process proc)))))


;;; input routines

;; comint-input-sender is set to this function, so that it is called by
;; comint-send-input.  This differs from comint-simple-send in that it
;; terminates the line with a carriage return instead of a linefeed;
;; although silverchat can be toggled to map LF->CR, that makes it
;; impossible to send multi-line input.
(defun agchat-simple-send (proc string)
  (comint-send-string proc string)
  (comint-send-string proc "\r"))

;; This might be useful for sending login sequences via agchat-connect-hook.
(defun agchat-send-sequence (&rest commands)
  (let ((proc (get-buffer-process (current-buffer))))
    (while commands
      (if (stringp (car commands))
          (agchat-simple-send proc (car commands))
        (apply 'agchat-send-sequence (car commands)))
      ; Not sure that this is effective, so skip it for now.
      ;(accept-process-output proc)
      (setq commands (cdr commands)))))

;; This should be on comint-input-filter-functions.
;; This removes the text just typed because the server echoes it back (with
;; modifications).  We do not simply use comint-process-echoes because in
;; Emacs 21, the original input will not be deleted if the echoed input
;; does not match exactly.
(defun agchat-delete-input-region (input)
  (let* ((pmark (process-mark (get-buffer-process (current-buffer))))
        (end (+ pmark (length input))))
    (delete-region pmark end)))

;; This should be added to pre-command-hook.
(defun agchat-goto-eob-on-insert-before-process-mark (&optional proc)
  (or proc (setq proc (get-buffer-process (current-buffer))))
  (cond
   ((null proc))
   ((not (eq this-command 'self-insert-command)))
   ((>= (point) (process-mark proc)))
   (t
    (goto-char (point-max)))))


;;; output routines

(defun agchat-display-output (proc string)
  (let ((orig-buffer (current-buffer)))
    (set-buffer (process-buffer proc))

    (let* ((saved-point (point-marker))
           (marker (process-mark proc))
           (buffer (process-buffer proc))
           (window (get-buffer-window buffer)))
      (save-restriction
        (widen)
        (narrow-to-region marker marker)

        (goto-char (point-min))
        (insert-before-markers-and-inherit string)
        (and window
             (= (marker-position marker) (window-start window))
             (set-window-start window (point-min) 'noforce))

        (let ((fns agchat-output-filter-functions))
        (while fns
          (goto-char (point-min))
          (funcall (car fns) string)
          (setq fns (cdr fns)))))
      (goto-char saved-point))
    (set-buffer orig-buffer)))

(defun agchat-default-output-filter (&optional string)
  (let ((re agchat-default-output-filter-regexp-list))
    (save-match-data
      (while re
        (goto-char (point-min))
        (while (re-search-forward (car re) nil t)
          (delete-region (match-beginning 0) (match-end 0)))
        (setq re (cdr re))))))

(defun agchat-popup (s)
  (and (fboundp 'pb-popup)
       (save-match-data
         (let ((re agchat-popup-regexp-list))
           (while re
             (cond ((string-match (car re) s)
                    (setq re nil)
                    (pb-popup (current-buffer)))
                   (t
                    (setq re (cdr re)))))))))

(defun agchat-output-beep (&optional string)
  (save-match-data
    (and (string-match "\C-g" string)
         (beep t))))

(defun agchat-message-timestamp (&optional string)
  "Insert timestamp in front of messages.
The variable `agchat-message-timestamp-format' specifies the timestamp
format as implemented by `format-time-string'.
This function should go on `agchat-output-filter-functions'."
  (goto-char (point-min))
  (save-match-data
    (while (re-search-forward "[P<*]?#[0-9]+:C" nil t)
      (goto-char (match-beginning 0))
      (let ((s (format-time-string agchat-message-timestamp-format)))
        (insert-before-markers-and-inherit s)
        (goto-char (+ (match-end 0) (length s)))))))


;;; Color handling

(defun agchat-color-filter (&optional string)
  (goto-char (point-min))
  (save-match-data
    (while (re-search-forward agchat-color-mode-regexp nil t)
      (let* ((beg (match-beginning 0))
             (end (point-max))
             (s (agchat-match-string 0))
             (fg (string-to-int (agchat-match-string 1)))
             (bg (string-to-int (agchat-match-string 3)))
             (bright (and (match-beginning 2) t)))

        ;; Get rid of the escape sequences; we no longer need them.
        (delete-region beg (match-end 0))
        (setq end (- end (- (match-end 0) beg)))

        (cond ((re-search-forward agchat-color-mode-regexp nil t)
               (setq end (point))
               (goto-char (match-beginning 0))))

        (agchat-colorize-region beg end fg bg bright)))))

(defun agchat-colorize-region (beg end fg bg &optional bright)
  (setq fg (agchat-color-lookup fg bright))
  (setq bg (agchat-color-lookup bg))
  (if (stringp fg)
      (setq bright nil)
    (setq bright 'bold)
    (setq fg (car fg)))
  (add-text-properties beg end
                       (list 'face (agchat-face-lookup fg bg bright)
                             'front-sticky   t
                             'rear-nonsticky t)))

(defun agchat-color-lookup (n &optional bright)
  (cond ((stringp n) n)
        (t
         (let* ((scheme (cdr (assq agchat-color-scheme
                                   agchat-color-scheme-table)))
                (cell (assq n scheme)))
           (if bright
               (or (nth 2 cell)
                   (cons (nth 1 cell) 'bold))
             (nth 1 cell))))))

(defun agchat-face-lookup (fg bg bold)
  (let ((face))
    (cond (agchat-colors-need-faces-p
           (setq face (intern (format "agchat:fg=%s:bg=%s:%s"
                                      fg bg (if bold "bold" "normal"))))
           (cond ((not (facep face))
                  (make-face face)
                  (set-face-foreground face fg)
                  (set-face-background face bg)
                  (and bold
                       (make-face-bold face)))))
          (t
           ;; Emacs 20 and later can accept a property list for face
           ;; attributes in text properties or overlays, without actually
           ;; having to allocate a face name.
           (setq face `((background-color . ,bg)
                        (foreground-color . ,fg)))
           (and bold
                (setq face (cons '(bold) face)))))
    face))


;;; misc utility routines

(defun agchat-delete-process (&optional proc)
  (or proc
      (setq proc (get-buffer-process (current-buffer))))
  (and (processp proc)
       (delete-process proc)))

(defun agchat-make-local-variables (&rest symlist)
  (let (sym)
    (while symlist
      (setq sym (car symlist))
      (cond
       ((assq sym (buffer-local-variables)))
       ((and (boundp sym)
             (sequencep sym))
        (make-local-variable sym)
        (set sym (copy-sequence (default-value sym))))
       (t
        (make-local-variable sym)))
      (setq symlist (cdr symlist)))))

(defun agchat-match-string (n &optional str)
  (and (match-beginning n)
       (if str
           (substring str (match-beginning n) (match-end n))
         (buffer-substring (match-beginning n) (match-end n)))))

(provide 'agchat)

;;; agchat.el ends here.
