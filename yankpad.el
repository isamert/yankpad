;;; yankpad.el --- Paste snippets from an org-mode file         -*- lexical-binding: t; -*-

;; Copyright (C) 2016--present Erik Sjöstrand
;; MIT License

;; Author: Erik Sjöstrand
;; URL: http://github.com/Kungsgeten/yankpad
;; Version: 2.50
;; Keywords: abbrev convenience
;; Package-Requires: ((emacs "25.1"))

;;; Commentary:

;; A way to insert text snippets from an org-mode file.  The org-mode file in
;; question is defined in `yankpad-file' and is set to "yankpad.org" in your
;; `org-directory' by default.  In this file, each heading specifies a snippet
;; category and each subheading of that category defines a snippet.  This way
;; you can have different yankpads for different occasions.
;;
;; You can open your `yankpad-file' by using `yankpad-edit' (or just open it in
;; any other way).  Another way to add new snippets is by using
;; `yankpad-capture-snippet', which will add a snippet to the current
;; `yankpad-category'.  After editing the `yankpad-file', do M-x yankpad-reload.
;;
;; If you have yasnippet installed, yankpad will try to use it when pasting
;; snippets.  This means that you can use the features that yasnippet provides
;; (tab stops, elisp, etc).  You can use yankpad without yasnippet, and then the
;; snippet will simply be inserted as is.
;;
;; You can also add keybindings to snippets, by setting an `org-mode' tag on the
;; snippet.  The last tag will be interpreted as a keybinding, and the snippet
;; can be run by using `yankpad-map' followed by the key.  `yankpad-map' is not
;; bound to any key by default.
;;
;; Another functionality is that snippets can include function calls, instead of
;; text.  In order to do this, the snippet heading should have a tag named
;; "func".  The snippet name could either be the name of the elisp function that
;; should be executed (will be called without arguments), or the content of the
;; snippet could be an `org-mode' src-block, which will then be executed when
;; you use the snippet.
;;
;; If you name a category to a major-mode name, that category will be switched
;; to when you change major-mode.  You can also name categories to the same name
;; as your project.el or projectile projects.  These snippets will be appended to
;; your active snippets if you change category.
;;
;; To insert a snippet from the yankpad, use `yankpad-insert' or
;; `yankpad-expand'.  `yankpad-expand' will look for a keyword at point, and
;; expand a snippet with a name starting with that word, followed by
;; `yankpad-expand-separator' (a colon by default).  If you need to change the
;; category, use `yankpad-set-category'.  If you want to append snippets from
;; another category (basically having several categories active at the same
;; time), use `yankpad-append-category'.  You can also use `yankpad-capf'.
;;
;; A quick way to add short snippets with a keyword is to add a descriptive list
;; to the category in your `yankpad-file'.  The key of each item in the list will be
;; the keyword, and the description will be the snippet.  You can turn off this
;; behaviour by setting `yankpad-descriptive-list-treatment' to nil, or change
;; descriptive lists to use `abbrev-mode' by setting the variable to 'abbrev
;; instead.
;;
;; For further customization, please see the Github page: https://github.com/Kungsgeten/yankpad
;;
;; Here's an example of what yankpad.org could look like:

;;; Yankpad example:

;; * Category 1
;; ** Snippet 1
;;
;;    This is a snippet.
;;
;; ** snip2: Snippet 2
;;
;;    This is another snippet.  This snippet can be expanded by first typing "snip2" and
;;    then executing the `yankpad-expand' command.
;;    \* Org-mode doesn't like lines beginning with *
;;    Typing \* at the beginning of a line will be replaced with *
;;
;;    If yanking a snippet into org-mode, this will respect the
;;    current tree level by default.  Set the variable
;;    `yankpad-respect-current-org-level' to nil in order to change that.
;;
;; * Category 2
;;
;;   Descriptive lists will be treated as snippets.  You can set them to be
;;   treated as `abbrev-mode' abbrevs instead, by setting
;;   `yankpad-descriptive-list-treatment' to abbrev.  If a heading could be considered
;;   to be a snippet, add the `snippetlist' tag to ignore the snippet and scan
;;   it for descriptive lists instead.
;;
;;   - name :: Erik Sjöstrand
;;   - key :: Typing "key" followed by `yankpad-expand' will insert this snippet.
;;
;; ** Snippet 1
;;
;;    This is yet another snippet, in a different category.
;; ** Snippet 2        :s:
;;
;;    This snippet will be bound to "s" when using `yankpad-map'.  Let's say you
;;    bind `yankpad-map' to f7, you can now press "f7 s" to insert this snippet.
;;
;; ** magit-status          :func:
;; ** Run magit-status      :func:m:
;;    #+BEGIN_SRC emacs-lisp
;;    (magit-status)
;;    #+END_SRC
;;
;; * org-mode
;; ** Snippet 1
;;    This category will be switched to automatically when visiting an org-mode buffer.
;;
;; * Category 3
;;   :PROPERTIES:
;;   :INCLUDE:  Category 1|Category 2
;;   :END:
;; ** A snippet among many!
;;    This category will include snippets from Category 1 and Category 2.
;;    This is done by setting the INCLUDE property of the category.
;;
;; * Global category       :global:
;; ** Always available
;;    Snippets in a category with the :global: tag are always available for expansion.
;; * Default                                           :global:
;; ** Fallback for major-mode categories
;;
;; If you open a file, but have no category named after its major-mode, a
;; category named "Default" will be used instead (if you have it defined in your
;; Yankpad).  It is probably a good idea to make this category global. You can
;; change the name of the default category by setting the variable
;; yankpad-default-category.
;;
;; * Local variables :noexport:
;; # Headlines tagged with :noexport: are not considered categories
;; # Adding yankpad-reload to the after-save-hook of the yankpad-file is a recommendation.
;; # Local Variables:
;; # eval: (add-hook 'after-save-hook #'yankpad-reload nil 'local)
;; # End:

;;; Code:

(require 'org-element)
(require 'org-capture)
(require 'org-macs)
(require 'thingatpt)
(require 'subr-x)
(require 'seq)
(require 'cl-lib)
(when (version< (org-version) "8.3")
  (require 'ox))

(defgroup yankpad nil
  "Paste snippets from an org-mode file."
  :group 'editing)

(defcustom yankpad-file (expand-file-name "yankpad.org" org-directory)
  "The path to your yankpad."
  :type 'string
  :group 'yankpad)

(defvar yankpad-category nil
  "The current yankpad category.  Change with `yankpad-set-category'.")
(put 'yankpad-category 'safe-local-variable #'string-or-null-p)

(defcustom yankpad-default-category "Default"
  "Used as fallback if no category is found when running `yankpad-local-category-to-major-mode'."
  :type 'string
  :group 'yankpad)

(defcustom yankpad-category-heading-level 1
  "The `org-mode' heading level of categories in the `yankpad-file'."
  :type 'integer
  :group 'yankpad)

(defcustom yankpad-respect-current-org-level t
  "Whether to respect `org-current-level' when using \* in snippets and yanking them into `org-mode' buffers."
  :type 'boolean
  :group 'yankpad)

(defcustom yankpad-auto-category-functions
  '(yankpad-major-mode-category
    yankpad-project-category
    yankpad-projectile-category)
  "List of functions that return an implicit category name.

Each item is a function that returns a category name or
nil. Categories returned from these functions are added as well
as the category explicitly selected by the user and global
categories."
  :type '(repeat function))

(defvar yankpad-switched-category-hook nil
  "Hooks run after changing `yankpad-category'.")

(defvar yankpad-before-snippet-hook nil
  "Hooks run before inserting a snippet.
Each hook function should take the snippet as an argument.
The snippet can be modified by using `setf' or similar.
A snippet is a list with the following elements:
\(name tags src-blocks content properties\)")

(defcustom yankpad-expand-separator ":"
  "String used to separate a keyword, at the start of a snippet name, from the title.  Used for `yankpad-expand'."
  :type 'string
  :group 'yankpad)

(defvar-local yankpad--active-snippets nil
  "A cached version of the snippets active in the current buffer.")

(defvar-local yankpad--active-snippets-generation -1
  "Generation of `yankpad--active-snippets' in the current buffer.")

(defvar-local yankpad--active-snippets-category nil
  "Category used to build `yankpad--active-snippets'.")

(defvar-local yankpad--active-snippets-category-local-p nil
  "Whether the category used to build the active cache was buffer-local.")

(defvar-local yankpad--active-snippets-file nil
  "Value of `yankpad-file' used to build the active cache.")

(defvar-local yankpad--automatic-category-source nil
  "Source which automatically selected `yankpad-category'.")

(defvar-local yankpad--automatic-category-value nil
  "Value last assigned automatically to `yankpad-category'.")

(defvar-local yankpad--automatic-category-generation -1
  "Cache generation when `yankpad-category' was selected automatically.")

(defvar-local yankpad--automatic-category-file nil
  "Absolute `yankpad-file' used for automatic category selection.")

(defvar yankpad--major-mode-override nil
  "Dynamically bound major mode used for automatic category lookup.")

(defvar yankpad--category-override nil
  "Dynamically bound category used by context-sensitive commands.")

(defvar yankpad--file-cache nil
  "Cached Org elements of `yankpad-file'.")

(defvar yankpad--file-cache-file nil
  "Absolute file name represented by `yankpad--file-cache'.")

(defvar yankpad--cache nil
  "An alist of category names and their parsed snippets.")

(defvar yankpad--cache-file nil
  "Absolute file name represented by `yankpad--cache'.")

(defvar yankpad--cache-valid-p nil
  "Non-nil when `yankpad--cache' is complete.")

(defvar yankpad--cache-generation 0
  "Generation counter used to invalidate buffer-local active caches.")

(defvar yankpad--parsing-categories nil
  "Categories in the cache currently being built.")

(defvar yankpad--link-stack nil
  "Link targets currently being scanned for snippets.")

(defvar yankpad--last-snippet nil
  "The last snippet executed. Used by `yankpad-repeat'.")

(defcustom yankpad-descriptive-list-treatment 'snippet
  "How items inside descriptive lists of `yankpad-category-heading-level' should be treated.

If nil, `yankpad' will ignore them.

If 'snippet, `yankpad' will treat them as snippets, where the key
of the description will be treated as a keyword in `yankpad'.

If 'abbrev, the items will overwrite `local-abbrev-table'."
  :type '(choice
          (const :tag "Snippet" snippet)
          (const :tag "Local abbrev" abbrev)
          (const :tag "Ignore" nil))
  :group 'yankpad)

(defcustom yankpad-global-tag "global"
  "Snippets in a category with this tag are always active."
  :type 'string
  :group 'yankpad)

(defcustom yankpad-use-yasnippet t
  "If non-nil and yasnippet is available, use it when pasting
snippets."
  :type 'boolean
  :group 'yankpad)

(defcustom yankpad-exclude-buffers-regexp "^\\*.+\\*$"
  "Regexp to check against buffer names to disable loading of yankpad snippets.
Buffers with matching names will not load yankpad snippets.
Note that `yankpad-local-category-to-major-mode' also exclude hidden buffers."
  :type 'string
  :group 'yankpad)

(defun yankpad--current-category ()
  "Return the category effective in the current command context."
  (or yankpad--category-override yankpad-category))

(defun yankpad--active-snippets-valid-p ()
  "Return non-nil when the current buffer's active cache is valid."
  (and (= yankpad--active-snippets-generation yankpad--cache-generation)
       (equal yankpad--active-snippets-category
              (yankpad--current-category))
       (eq yankpad--active-snippets-category-local-p
           (local-variable-p 'yankpad-category))
       (equal yankpad--active-snippets-file yankpad-file)))

(defun yankpad--invalidate-active-snippets ()
  "Invalidate the active snippet cache in the current buffer."
  (setq yankpad--active-snippets nil
        yankpad--active-snippets-generation -1
        yankpad--active-snippets-category nil
        yankpad--active-snippets-category-local-p nil
        yankpad--active-snippets-file nil))

(defun yankpad-active-snippets ()
  "Get the snippets active in the current buffer."
  (if (yankpad--active-snippets-valid-p)
      yankpad--active-snippets
    (yankpad-set-active-snippets)))

;;;###autoload
(defun yankpad-set-category (&optional category)
  "Change `yankpad-category' to CATEGORY.
Prompt for CATEGORY when it is nil."
  (interactive)
  (let ((categories (yankpad--categories)))
    (cond
     ((null categories)
      (user-error "Your yankpad file doesn't contain any categories"))
     ((and category (not (member category categories)))
      (user-error "No Yankpad category named `%s'" category))
     ((null category)
      (setq category
            (if (null (cdr categories))
                (car categories)
              (completing-read "Category: " categories nil t)))))
    (setq yankpad-category category
          yankpad--automatic-category-source nil
          yankpad--automatic-category-value nil
          yankpad--automatic-category-generation -1
          yankpad--automatic-category-file nil))
  (yankpad--invalidate-active-snippets)
  (run-hooks 'yankpad-switched-category-hook)
  yankpad-category)

(defun yankpad-set-local-category (category &optional automatic-source)
  "Set `yankpad-category' to CATEGORY locally.
AUTOMATIC-SOURCE records the internal automatic selector, if any."
  (setq-local yankpad-category category)
  (setq yankpad--automatic-category-source automatic-source
        yankpad--automatic-category-value (and automatic-source category)
        yankpad--automatic-category-generation
        (if automatic-source yankpad--cache-generation -1)
        yankpad--automatic-category-file
        (and automatic-source (expand-file-name yankpad-file)))
  (yankpad--invalidate-active-snippets)
  (run-hooks 'yankpad-switched-category-hook)
  category)

(defsubst yankpad-major-mode-category ()
  "Return a category name based on the effective major mode."
  (symbol-name (or yankpad--major-mode-override major-mode)))

(defun yankpad--category-for-mode (mode)
  "Return the Yankpad category matching MODE, or the fallback category."
  (let ((categories (yankpad--categories)))
    (or (car (member (symbol-name mode) categories))
        (car (member yankpad-default-category categories)))))

(defun yankpad--org-src-edit-buffer-p ()
  "Return non-nil in a buffer created to edit an Org source block."
  (and (bound-and-true-p org-src-mode)
       (boundp 'org-src--beg-marker)
       (markerp org-src--beg-marker)
       (marker-buffer org-src--beg-marker)))

(defun yankpad--org-src-block-mode-at-point ()
  "Return the language mode when point is inside an Org source block."
  (when (and (derived-mode-p 'org-mode)
             (org-in-src-block-p t))
    (let* ((element (org-element-context))
           (language (and (eq (org-element-type element) 'src-block)
                          (org-element-property :language element))))
      (when language
        (require 'org-src)
        (org-src-get-lang-mode language)))))

(defmacro yankpad--with-org-src-block-context (&rest body)
  "Evaluate BODY using the mode category of an Org source block at point."
  (declare (indent 0) (debug t))
  (let ((mode (make-symbol "mode")))
    `(let* ((,mode (yankpad--org-src-block-mode-at-point))
            (yankpad--major-mode-override ,mode)
            (yankpad--category-override
             (and ,mode (yankpad--category-for-mode ,mode))))
       ,@body)))

(defsubst yankpad-projectile-category ()
  "Return a category name based on the projectile project name."
  (when (require 'projectile nil t)
    (projectile-project-name)))

(defsubst yankpad-project-category ()
  "Return a category name based on the project.el project name."
  (when (require 'project nil t)
    (when-let ((proj (project-current)))
      (project-name proj))))

(defun yankpad--ensure-category ()
  "Ensure that the current buffer has a Yankpad category.
Try automatic major-mode selection before prompting."
  ;; This also handles buffers whose major mode was initialized before
  ;; Yankpad was loaded.  An explicitly buffer-local nil value opts out of
  ;; automatic selection, as documented for file-local variables.
  (unless (or yankpad--category-override
              (local-variable-p 'yankpad-category))
    (yankpad-local-category-to-major-mode))
  (or (yankpad--current-category) (yankpad-set-category)))

(defun yankpad--append-category-snippets (category)
  "Append snippets from CATEGORY to the current buffer's active cache."
  (unless (equal category (yankpad--current-category))
    (dolist (snippet (yankpad--snippets category))
      (add-to-list 'yankpad--active-snippets snippet t))))

(defun yankpad--refresh-automatic-category ()
  "Refresh a stale automatically selected category.
Do not override a category changed directly or through file-local
variables since automatic selection took place."
  (when yankpad--automatic-category-source
    (if (not (equal yankpad-category yankpad--automatic-category-value))
        (setq yankpad--automatic-category-source nil
              yankpad--automatic-category-value nil
              yankpad--automatic-category-generation -1
              yankpad--automatic-category-file nil)
      ;; File- and directory-local variables are applied after the major-mode
      ;; hook.  Re-evaluate an automatic choice when they select another
      ;; Yankpad file, rather than retaining a category from the old file.
      (when (or (< yankpad--automatic-category-generation
                   yankpad--cache-generation)
                (not (equal yankpad--automatic-category-file
                            (expand-file-name yankpad-file))))
        (let ((source yankpad--automatic-category-source))
          (unless
              (pcase source
                ('major-mode (yankpad-local-category-to-major-mode))
                ('projectile
                 (or (yankpad-local-category-to-projectile)
                     (yankpad-local-category-to-major-mode))))
            (kill-local-variable 'yankpad-category)
            (setq yankpad--automatic-category-source nil
                  yankpad--automatic-category-value nil
                  yankpad--automatic-category-generation -1
                  yankpad--automatic-category-file nil)))))))

(defun yankpad-set-active-snippets ()
  "Set snippets active for the effective category in the current buffer.
Also append implicit and global categories."
  (unless yankpad--category-override
    (yankpad--refresh-automatic-category))
  (yankpad--ensure-category)
  (let ((category (yankpad--current-category)))
    (unless (member category (yankpad--categories))
      (user-error "Current Yankpad category `%s' was not found" category))
    ;; Copy the list spine so appending categories can never modify the parsed
    ;; category cache.
    (setq yankpad--active-snippets
          (copy-sequence (yankpad--snippets category)))
    (when (or yankpad--category-override
              (local-variable-p 'yankpad-category))
      (thread-last (mapcar #'funcall yankpad-auto-category-functions)
                   (delq nil)
                   (seq-intersection (yankpad--categories))
                   (mapc #'yankpad--append-category-snippets)))
    (mapc #'yankpad--append-category-snippets (yankpad--global-categories))
    (setq yankpad--active-snippets-generation yankpad--cache-generation
          yankpad--active-snippets-category category
          yankpad--active-snippets-category-local-p
          (local-variable-p 'yankpad-category)
          yankpad--active-snippets-file yankpad-file)
    (when yankpad--automatic-category-source
      (setq yankpad--automatic-category-generation yankpad--cache-generation
            yankpad--automatic-category-value yankpad-category))
    yankpad--active-snippets))

(defun yankpad-append-category (category)
  "Add snippets from CATEGORY into the list of active snippets.
Prompt for CATEGORY interactively."
  (interactive
   (list (completing-read "Category: " (yankpad--categories) nil t)))
  (unless (member category (yankpad--categories))
    (user-error "No Yankpad category named `%s'" category))
  (unless (yankpad--active-snippets-valid-p)
    (yankpad-set-active-snippets))
  (yankpad--append-category-snippets category)
  yankpad--active-snippets)

(defun yankpad--add-abbrevs-from-category (category)
  "`define-abbrev' in `local-abbrev-table' for each descriptive list item in CATEGORY."
  (dolist (abbrev (yankpad-category-descriptions category))
    (define-abbrev local-abbrev-table (car abbrev) (cdr abbrev))))

(defun yankpad-load-abbrevs ()
  "Load abbrevs related to `yankpad-category'."
  (if-let* ((major-abbrev-table (intern-soft (concat (symbol-name major-mode) "-abbrev-table"))))
      (setq local-abbrev-table (copy-abbrev-table (eval major-abbrev-table)))
    (clear-abbrev-table local-abbrev-table))
  (yankpad--add-abbrevs-from-category yankpad-category)
  (mapc #'yankpad--add-abbrevs-from-category (yankpad--global-categories))
  (when (local-variable-p 'yankpad-category)
    (let ((categories (yankpad--categories)))
      (when-let* ((major-mode-category (car (member (symbol-name major-mode)
                                                    categories))))
        (yankpad--add-abbrevs-from-category major-mode-category))
      (when (require 'projectile nil t)
        (when-let* ((projectile-category (car (member (projectile-project-name)
                                                      categories))))
          (yankpad--add-abbrevs-from-category projectile-category)))
      (when (require 'project nil t)
        (when-let* ((proj (project-current))
                    (project-category (car (member (project-name proj)
                                                   categories))))
          (yankpad--add-abbrevs-from-category project-category))))))

(defun yankpad-reload ()
  "Clear and rebuild all snippet caches from `yankpad-file'.
If `yankpad-descriptive-list-treatment' is `abbrev', scan
`yankpad-category' for abbrevs as well."
  (interactive)
  (yankpad--rebuild-cache t)
  (when (and (eq yankpad-descriptive-list-treatment 'abbrev)
             yankpad-category)
    (yankpad-load-abbrevs)))

;;;###autoload
(defun yankpad-insert ()
  "Insert an entry from the yankpad.
Uses `yankpad-category', and prompts for it if it isn't set."
  (interactive)
  (yankpad--with-org-src-block-context
   (yankpad--ensure-category)
   (yankpad-insert-from-current-category)))

(defun yankpad-snippet-text (snippet)
  "Get text from SNIPPET, as a string.
SNIPPET can be a list: Yankpad's internal representation of
snippets. It can also be a string, in which case it should match
a snippet name in the current category."
  (if (stringp snippet)
      (if-let ((real-snippet (assoc snippet (yankpad-active-snippets))))
          (yankpad-snippet-text real-snippet)
        (error (concat "No snippet named " snippet)))
    (let ((snippet (copy-sequence snippet)))
      (let ((name (car snippet))
            (tags (nth 1 snippet))
            (src-blocks (nth 2 snippet))
            (content (nth 3 snippet)))
        (cond
         (src-blocks
          (yankpad-snippet-text
           (list name tags nil
                 (string-trim-right
                  (mapconcat
                   (lambda (x)
                     (org-remove-indentation (org-element-property :value x)))
                   src-blocks "")
                  "\n"))))
         ((or (member "func" tags)
              (member "results" tags))
          (yankpad--trigger-snippet-function name content))
         (t
          (if (string-empty-p content)
              (message (concat "\"" name "\" snippet doesn't contain any text. Check your yankpad file."))
            ;; Respect the tree level when yanking org-mode headings.
            (let ((prepend-asterisks 1))
              (when (and (equal major-mode 'org-mode)
                         (or yankpad-respect-current-org-level
                             (member "orglevel" tags))
                         (not (member "no_orglevel" tags))
                         (org-current-level))
                (setq prepend-asterisks (org-current-level)))
              (replace-regexp-in-string
               "^\\\\?[*]" (make-string prepend-asterisks ?*) content)))))))))

(defun yankpad--use-yasnippet ()
  "Determine if we can use yasnippet for pasting snippets.

The yasnippet package must be available and the setting
`yankpad-use-yasnippet' (default t) must be non-nil."
  (and yankpad-use-yasnippet
       (require 'yasnippet nil t)))

(defun yankpad--insert-snippet-text (text indent wrap)
  "Insert TEXT into buffer.  INDENT is whether/how to indent the snippet.
WRAP is the value for `yas-wrap-around-region', if `yasnippet' is available.
Use yasnippet and `yas-indent-line' if available."
  (if (and (yankpad--use-yasnippet)
           yas-minor-mode)
      (if (region-active-p)
          (yas-expand-snippet text (region-beginning) (region-end)
                              `((yas-indent-line (quote ,indent))
                                (yas-wrap-around-region (quote ,wrap))))
        (yas-expand-snippet text nil nil `((yas-indent-line (quote ,indent)))))
    (let ((start (point)))
      (insert text)
      (when indent
        (indent-region start (point))))))

(defun yankpad--trigger-snippet-function (snippetname content)
  "SNIPPETNAME can be an elisp function, without arguments, if CONTENT is nil.
If non-nil, CONTENT should hold a single `org-mode' src-block, to be executed.
Return the result of the function output as a string."
  (if (string-empty-p (string-trim content))
      (if (intern-soft snippetname)
          (prin1-to-string (funcall (intern-soft snippetname)))
        (error (concat "\"" snippetname "\" isn't a function")))
    (with-temp-buffer
      (delay-mode-hooks
        (org-mode)
        (insert content)
        (goto-char (point-min))
        (if (or (org-in-src-block-p)
                (and (ignore-errors (org-next-block 1))
                     (org-in-src-block-p)))
            (let ((result (org-babel-execute-src-block)))
              (if (stringp result) result (prin1-to-string result)))
          (error "First block in snippet must be an org-mode src block"))))))

(defun yankpad--run-snippet (snippet)
  "Triggers the SNIPPET behaviour."
  (setq yankpad--last-snippet snippet)
  (let ((snippet (copy-sequence snippet)))
    (run-hook-with-args 'yankpad-before-snippet-hook snippet)
    (let ((tags (nth 1 snippet)))
      (cond
       ((member "func" tags)
        (yankpad-snippet-text snippet))
       (t
        (let ((indent (cond ((member "indent_nil" tags)
                             nil)
                            ((member "indent_fixed" tags)
                             'fixed)
                            ((member "indent_auto" tags)
                             'auto)
                            ((and (yankpad--use-yasnippet) yas-minor-mode)
                             yas-indent-line)
                            (t t)))
              (wrap (cond ((or (not (and (yankpad--use-yasnippet) yas-minor-mode))
                               (member "wrap_nil" tags))
                           nil)
                          ((member "wrap" tags)
                           t)
                          (t yas-wrap-around-region))))
          (yankpad--insert-snippet-text (yankpad-snippet-text snippet) indent wrap)))))))

(defun yankpad-repeat ()
  "Repeats the last used snippet."
  (interactive)
  (if yankpad--last-snippet
      (yankpad--run-snippet yankpad--last-snippet)
    (error "There has been no previous snippet")))

(defun yankpad--remove-id-from-yankpad-capture ()
  "Remove ID property from last `yankpad-capture-snippet', save `yankpad-file'."
  (let* ((properties (ignore-errors (org-entry-properties org-capture-last-stored-marker)))
         (file (cdr (assoc "FILE" properties))))
    (when (and file (file-equal-p file yankpad-file))
      (when (org-entry-delete org-capture-last-stored-marker "ID")
        (with-current-buffer (get-file-buffer file)
          (save-buffer)))
      (yankpad-reload))))
(add-hook 'org-capture-after-finalize-hook #'yankpad--remove-id-from-yankpad-capture)

;;;###autoload
(defun yankpad-capture-snippet ()
  "`org-capture' a snippet to current `yankpad-category' (prompts if not set)."
  (interactive)
  (yankpad--ensure-category)
  (let ((org-capture-entry
         `("y" "Yankpad" entry (file+headline ,yankpad-file ,yankpad-category)
           "* %?\n%i")))
    (org-capture)))

(defun yankpad-insert-from-current-category (&optional name)
  "Insert snippet NAME from `yankpad-category'.  Prompts for NAME unless set.
Does not change `yankpad-category'."
  (let ((snippets (yankpad-active-snippets)))
    (unless name
      (setq name (completing-read "Snippet: " snippets)))
    (if-let ((snippet (assoc name (yankpad-active-snippets))))
        (yankpad--run-snippet snippet)
      (message (concat "No snippet named " name))
      nil)))

(defun yankpad-keyword-with-bounds-at-point ()
  "Get current keyword and its bounds."
  (save-excursion
    (let (beg (end (point)))
      (when (re-search-backward "\\([[:blank:]\n]\\|^\\)" nil t 1)
        (setq beg (if (bolp)
                      (point)
                    (1+ (point))))
        (cons (buffer-substring-no-properties beg end) (cons beg end))))))

;;;###autoload
(defun yankpad-expand (&optional _first)
  "Replace symbol at point with a snippet.
Only works if the symbol is found in the first matching group of
`yankpad-expand-keyword-regex'.

This function can be added to `hippie-expand-try-functions-list'."
  (interactive)
  (yankpad--with-org-src-block-context
   (when (called-interactively-p 'any)
     (yankpad--ensure-category))
   (let* ((symbol-with-bounds (yankpad-keyword-with-bounds-at-point))
          (symbol (car symbol-with-bounds))
          (bounds (cdr symbol-with-bounds))
          (possible-snippets '())
          (case-fold-search nil))
     (when (and symbol (yankpad--current-category))
       (catch 'loop
         (mapc
          (lambda (snippet)
            ;; See if there's an expand regex
            (if-let ((regex (cdr (assoc "YP_EXPAND_REGEX" (nth 4 snippet)))))
                (when (string-match (concat "\\b" regex "\\b") symbol)
                  (let ((match (cddr (match-data)))
                        (snippet (copy-sequence snippet))
                        strings)
                    (while match
                      (push (substring symbol (pop match) (pop match)) strings))
                    (setf (nth 3 snippet)
                          (apply #'format (nth 3 snippet) (reverse strings)))
                    (delete-region (car bounds) (cdr bounds))
                    (yankpad--run-snippet snippet)
                    (throw 'loop snippet)))

              ;; Otherwise look for expand keyword
              (when (member symbol (butlast (split-string (car snippet) yankpad-expand-separator)))
                (delete-region (car bounds) (cdr bounds))
                (yankpad--run-snippet snippet)
                (throw 'loop snippet))

              ;; Collect suffix matches
              (let ((snippet-keyword (car (split-string (car snippet) yankpad-expand-separator))))
                (when (string-suffix-p snippet-keyword symbol)
                  (add-to-list 'possible-snippets (cons snippet-keyword snippet))))))
          (yankpad-active-snippets))

         ;; Find the longest suffix match and apply it, if we have one
         (when possible-snippets
           (let* ((snippet-info (seq-reduce
                                 (lambda (acc it)
                                   (if (> (length (car it)) (length acc))
                                       it acc))
                                 possible-snippets ""))
                  (snippet (cdr snippet-info))
                  (snippet-keyword (car snippet-info)))
             (delete-region (- (cdr bounds) (length snippet-keyword)) (cdr bounds))
             (yankpad--run-snippet (cdr snippet-info))
             (throw 'loop snippet)))
         nil)))))

;;;###autoload
(defun yankpad-edit ()
  "Open the yankpad file for editing."
  (interactive)
  (let ((category yankpad-category))
    (find-file-other-window yankpad-file)
    (when category
      (goto-char (yankpad-category-marker category))
      (org-show-entry)
      (org-show-subtree))))

(defun yankpad--file-elements ()
  "Return cached Org elements from `yankpad-file'."
  (let* ((file (expand-file-name yankpad-file))
         (source-buffer (get-file-buffer file)))
    (if (and yankpad--file-cache
             (equal yankpad--file-cache-file file))
        yankpad--file-cache
      (setq yankpad--file-cache-file file
            yankpad--file-cache
            (with-temp-buffer
              (delay-mode-hooks
                (org-mode)
                ;; Use the visiting buffer when there is one.  Parsing the
                ;; disk contents but looking up snippets in an edited buffer
                ;; makes cached positions point at the wrong headings.
                (if source-buffer
                    (insert
                     (with-current-buffer source-buffer
                       (org-with-wide-buffer
                        (buffer-substring-no-properties
                         (point-min) (point-max)))))
                  (insert-file-contents file))
                (org-element-parse-buffer)))))))

(defun yankpad--excluded-category-p (headline)
  "Return non-nil if HEADLINE has an Org export exclusion tag."
  (seq-some (lambda (tag)
              (member tag (org-element-property :tags headline)))
            (if (boundp 'org-export-exclude-tags)
                org-export-exclude-tags
              '("noexport"))))

(defun yankpad--categories ()
  "Get the yankpad categories as a list."
  (let ((data (yankpad--file-elements)))
    (org-element-map data 'headline
      (lambda (h)
        (when (and (equal (org-element-property :level h)
                          yankpad-category-heading-level)
                   (not (yankpad--excluded-category-p h)))
          (org-element-property :raw-value h))))))

(defun yankpad--global-categories ()
  "Get the yankpad categories with `yankpad-global-tag' as a list."
  (org-element-map (yankpad--file-elements) 'headline
    (lambda (h)
      (when (and (equal (org-element-property :level h)
                        yankpad-category-heading-level)
                 (not (yankpad--excluded-category-p h))
                 (member yankpad-global-tag (org-element-property :tags h)))
        (org-element-property :raw-value h)))))

(defun yankpad-category-marker (category)
  "Get marker to CATEGORY in `yankpad-file'."
  (org-element-map (yankpad--file-elements) 'headline
    (lambda (h)
      (when (and (equal (org-element-property :level h)
                        yankpad-category-heading-level)
                 (string-equal (org-element-property :raw-value h) category))
        (set-marker (make-marker)
                    (org-element-property :begin h)
                    (find-file-noselect (expand-file-name yankpad-file)))))
    nil t))

(defun yankpad--snippets-from-link-target (target function)
  "Call FUNCTION while scanning link TARGET, detecting cycles."
  (when (member target yankpad--link-stack)
    (user-error "Circular Yankpad snippet link involving `%s'" target))
  (let ((yankpad--link-stack (cons target yankpad--link-stack)))
    (funcall function)))

(defun yankpad-snippets-from-link (link)
  "Get snippets from Org LINK."
  (unless (string-match "\\`\\([[:alpha:]]+\\):\\(.+\\)\\'" link)
    (user-error "Malformed Yankpad snippet link `%s'" link))
  (let* ((type (match-string 1 link))
         (value (match-string 2 link))
         (parts (split-string value "::"))
         (file (car parts))
         (search (mapconcat #'identity (cdr parts) "::")))
    (cond
     ((string-equal type "id")
      (let ((marker (org-id-find value t)))
        (unless marker
          (user-error "Yankpad snippet ID `%s' was not found" value))
        (yankpad--snippets-from-link-target
         (list 'id (marker-buffer marker) (marker-position marker))
         (lambda ()
           (org-with-point-at marker
             (yankpad-snippets-at-point t))))))
     ((string-equal type "file")
      (let ((file (expand-file-name file)))
        (yankpad--snippets-from-link-target
         (list 'file file search)
         (lambda ()
           (with-current-buffer (find-file-noselect file)
             (org-with-wide-buffer
              (if (not (string-empty-p search))
                  (let ((org-link-search-must-match-exact-headline t))
                    (org-link-search search)
                    (yankpad-snippets-at-point t))
                ;; Scan each leaf once.  Calling
                ;; `yankpad-snippets-at-point' at every parent duplicated all
                ;; snippets in that parent's subtree.
                (cl-reduce
                 #'append
                 (org-map-entries
                  (lambda ()
                    (unless (save-excursion (org-goto-first-child))
                      (yankpad-snippets-at-point t)))
                  nil 'file)))))))))
     (t
      (user-error "Link type `%s' isn't supported by Yankpad" type)))))

(defun yankpad-snippets-at-point (&optional remove-props)
  "Return snippets at point.
If REMOVE-PROPS is non nil, `org-mode' property drawers will be
removed from the snippet text."
  (let* ((heading (substring-no-properties (org-get-heading t t t t)))
         (link (and (string-match org-bracket-link-regexp heading)
                    (match-string 1 heading))))
    (if link
        (yankpad-snippets-from-link link)
      (if (save-excursion (org-goto-first-child))
          (cl-reduce #'append
                     (org-map-entries
                      (lambda () (yankpad-snippets-at-point t))
                      (format "+LEVEL=%s" (1+ (org-current-level))) 'tree))
        (let* ((text (substring-no-properties (org-remove-indentation (org-get-entry))))
               (tags (org-get-tags))
               (src-blocks (when (member "src" tags)
			     (org-element-map
				 (with-temp-buffer (insert text) (org-element-parse-buffer))
				 'src-block #'identity)))
               (properties (when (member "props" tags) (org-entry-properties))))
          (if (member "snippetlist" tags)
              nil
            (when (or remove-props (member "props" tags))
              (setq text (string-trim-left
                          (replace-regexp-in-string org-property-drawer-re "" text))))
            (list (list heading tags src-blocks text properties))))))))

(defun yankpad--delete-duplicate-snippets (snippets)
  "Return SNIPPETS without duplicate entries, preserving their order."
  (let ((seen (make-hash-table :test #'equal))
        result)
    (dolist (snippet snippets (nreverse result))
      (unless (gethash snippet seen)
        (puthash snippet t seen)
        (push snippet result)))))

(defun yankpad--parse-snippets (category-name &optional ancestors)
  "Parse CATEGORY-NAME and cache its snippets.
ANCESTORS contains categories which include CATEGORY-NAME and is used
for cycle detection."
  (unless (stringp category-name)
    (user-error "Invalid Yankpad category: %S" category-name))
  (if-let ((cached (assoc-string category-name yankpad--cache)))
      (cdr cached)
    (when (member category-name ancestors)
      (user-error
       "Circular Yankpad INCLUDE: %s"
       (mapconcat #'identity
                  (append (reverse ancestors) (list category-name)) " -> ")))
    (unless (member category-name
                    (or yankpad--parsing-categories (yankpad--categories)))
      (user-error "Yankpad category `%s' included but not found" category-name))
    (let* ((marker (yankpad-category-marker category-name))
           (property-string (org-entry-get marker "INCLUDE"))
           (included-categories
            (and property-string
                 (split-string property-string "|" t "[[:space:]]+")))
           (snippets
            (append
             (when (eq yankpad-descriptive-list-treatment 'snippet)
               (mapcar
                (lambda (description)
                  (list (concat (car description) yankpad-expand-separator)
                        nil nil (cdr description)))
                (yankpad-category-descriptions category-name)))
             (org-with-point-at marker
               (cl-reduce #'append
                          (org-map-entries
                           #'yankpad-snippets-at-point
                           (format "+LEVEL=%s"
                                   (1+ yankpad-category-heading-level))
                           'tree)))))
           (included-snippets
            (apply #'append
                   (mapcar
                    (lambda (included)
                      (yankpad--parse-snippets
                       included (cons category-name ancestors)))
                    included-categories)))
           (all-snippets
            (yankpad--delete-duplicate-snippets
             (append snippets included-snippets))))
      (push (cons category-name all-snippets) yankpad--cache)
      all-snippets)))

(defun yankpad--rebuild-cache (&optional reread-file)
  "Rebuild parsed snippet caches transactionally.
When REREAD-FILE is non-nil, discard the cached Org elements and
refresh an unmodified visiting buffer from disk before parsing."
  (let* ((file (expand-file-name yankpad-file))
         (file-buffer (get-file-buffer file)))
    (when (and reread-file file-buffer
               (buffer-live-p file-buffer)
               (not (buffer-modified-p file-buffer))
               (not (verify-visited-file-modtime file-buffer)))
      (with-current-buffer file-buffer
        (revert-buffer t t t)))
    (let* ((reuse-file-cache
            (and (not reread-file)
                 (equal yankpad--file-cache-file file)
                 yankpad--file-cache))
           new-file-cache new-file-cache-file new-cache)
      ;; Dynamic bindings let parsing use a fresh cache while preserving the
      ;; previous working cache if malformed input raises an error.
      (let ((yankpad--file-cache reuse-file-cache)
            (yankpad--file-cache-file (and reuse-file-cache file))
            (yankpad--cache nil)
            (yankpad--cache-valid-p nil)
            (yankpad--cache-file nil)
            (yankpad--parsing-categories nil))
        (setq yankpad--parsing-categories (yankpad--categories))
        (dolist (category yankpad--parsing-categories)
          (yankpad--parse-snippets category))
        (setq new-file-cache yankpad--file-cache
              new-file-cache-file yankpad--file-cache-file
              new-cache yankpad--cache))
      (setq yankpad--file-cache new-file-cache
            yankpad--file-cache-file new-file-cache-file
            yankpad--cache new-cache
            yankpad--cache-file file
            yankpad--cache-valid-p t)
      (cl-incf yankpad--cache-generation)
      (yankpad--invalidate-active-snippets)
      yankpad--cache)))

(defun yankpad--snippets (category-name)
  "Get the cached snippets in CATEGORY-NAME.
Each snippet is a list (NAME TAGS SRC-BLOCKS TEXT PROPERTIES)."
  (let ((file (expand-file-name yankpad-file)))
    (unless (and yankpad--cache-valid-p
                 (equal yankpad--cache-file file))
      (yankpad--rebuild-cache)))
  (cdr (assoc-string category-name yankpad--cache)))

;;;###autoload
(defun yankpad-map ()
  "Create and execute a keymap out of the last tags of snippets in `yankpad-category'."
  (interactive)
  (define-prefix-command 'yankpad-keymap)
  (let (map-help)
    (mapc (lambda (snippet)
            (let ((last-tag (car (last (nth 1 snippet)))))
              (when (and last-tag
                         (not (string-prefix-p "indent_" last-tag))
                         (not (string-prefix-p "wrap" last-tag))
                         (not (member last-tag '("func" "results" "src" "props"))))
                (let ((heading (car snippet))
                      (key (substring-no-properties last-tag)))
                  (push (cons key (format "[%s] %s " key heading)) map-help)
                  (define-key yankpad-keymap (kbd key)
                              `(lambda ()
                                 (interactive)
                                 (yankpad--run-snippet ',snippet)))))))
          (yankpad-active-snippets))
    (let ((message-log-max nil))
      (message "yankpad: %s"
               (if map-help
                   (apply 'concat (mapcar 'cdr (sort map-help
                                                     (lambda (x y)
                                                       (string-lessp (car x) (car y))))))
                 (format "nothing is defined in %s" yankpad-category)))))
  (set-transient-map 'yankpad-keymap))

(defmacro yankpad-map-simulate (key)
  "Create and return a command which presses KEY in `yankpad-map'."
  `(defun ,(intern (concat "yankpad-map-press-" key)) ()
     ,(concat "Press '" key "' in `yankpad-map'.")
     (interactive)
     (setq unread-command-events (listify-key-sequence (kbd ,key)))
     (yankpad-map)))

(defun yankpad-local-category-to-major-mode ()
  "Try to change `yankpad-category' to match the buffer's major mode.
If successful, make `yankpad-category' buffer-local.
If no major mode category is found, it uses `yankpad-default-category',
if that is defined in the `yankpad-file'."
  (let ((name (buffer-name)))
    (unless (and (not (yankpad--org-src-edit-buffer-p))
                 (or (string-prefix-p " " name)
                     (string-match-p yankpad-exclude-buffers-regexp name)))
      (when (file-exists-p yankpad-file)
        (let* ((categories (yankpad--categories))
               (category (or (car (member (yankpad-major-mode-category)
                                          categories))
                             (car (member yankpad-default-category categories)))))
          (when category
            (yankpad-set-local-category category 'major-mode)))))))

(add-hook 'after-change-major-mode-hook #'yankpad-local-category-to-major-mode)
(with-eval-after-load 'org-src
  ;; `org-src-mode' is enabled after the language major mode, so the regular
  ;; major-mode hook has already skipped its normally excluded buffer name.
  (add-hook 'org-src-mode-hook #'yankpad-local-category-to-major-mode))
;; Run the function when yankpad is loaded
(yankpad-local-category-to-major-mode)

(defun yankpad-local-category-to-projectile ()
  "Try to change `yankpad-category' to match the `projectile-project-name'.
If successful, make `yankpad-category' buffer-local."
  (when (and (require 'projectile nil t)
             (file-exists-p yankpad-file))
    (when-let* ((category (car (member (projectile-project-name)
                                       (yankpad--categories)))))
      (yankpad-set-local-category category 'projectile))))

(eval-after-load "projectile"
  (add-hook 'projectile-find-file-hook #'yankpad-local-category-to-projectile))
;; Run the function when yankpad is loaded
(yankpad-local-category-to-projectile)

(with-eval-after-load "auto-yasnippet"
  (defun yankpad-aya-persist (name)
    "Add `aya-current' as NAME to `yankpad-category'."
    (interactive
     (if (eq aya-current "")
         (user-error "Aborting: You don't have a current auto-snippet defined")
       (list (read-string "Snippet name: "))))
    (unless yankpad-category (yankpad-set-category))
    (let ((org-capture-entry
           `("y" "Yankpad" entry (file+headline ,yankpad-file ,yankpad-category)
             ,(format "* %s\n%s\n" name aya-current)
             :immediate-finish t)))
      (org-capture))))

(defun yankpad-category-descriptions (category)
  "Get a list of all descriptions in CATEGORY.
Descriptions are fetched from descriptive lists in `org-mode',
under the same heading level as CATEGORY.
Each element is (KEY . DESCRIPTION), both strings."
  (org-with-point-at (yankpad-category-marker category)
    (org-narrow-to-subtree)
    (apply
     #'append
     (org-element-map (org-element-parse-buffer) 'plain-list
       (lambda (dl)
         (let ((parent (funcall (if (version< (org-version) "8.3")
                                    #'org-export-get-genealogy
                                  #'org-element-lineage)
                                dl '(headline))))
           (when (and (equal (org-element-property :type dl) 'descriptive)
                      (or (equal (org-element-property :level parent)
                                 yankpad-category-heading-level)
                          (save-excursion
                            (goto-char (org-element-property :begin parent))
                            (org-goto-first-child))
                          (member "snippetlist" (org-element-property :tags parent))))
             (org-element-map dl 'item
               (lambda (i)
                 (cons (org-no-properties (car (org-element-property :tag i)))
                       (string-trim (buffer-substring-no-properties
                                     (org-element-property :contents-begin i)
                                     (org-element-property :contents-end i)))))))))))))

(defun yankpad--get-completion-candidates (prefix snippets categories)
  "Return a list of completion candidates based on PREFIX and separator."
  (let ((candidates '())
        (sep yankpad-expand-separator))
    (dolist (cat categories)
      (when (string-prefix-p prefix cat t)
        (push cat candidates)))
    (dolist (snippet snippets)
      (let* ((name (car snippet))
             (name-parts (split-string name sep t))
             (keyword (car name-parts))
             (annotation (mapconcat 'identity (cdr name-parts) sep)))
        (when (and keyword (string-prefix-p prefix keyword t))
          (push (propertize keyword 'annotation annotation) candidates))))
    (sort (delete-dups candidates) #'string-lessp)))

(defun yankpad--doc-buffer (candidate)
  "Return a buffer with detailed documentation for the Yankpad CANDIDATE."
  (let ((snippets (yankpad-active-snippets)))
    (let* ((full-snippet-name
            (cl-find-if (lambda (snippet)
                          (string-prefix-p candidate (car snippet)))
                        snippets))
           (snippet (assoc (car full-snippet-name) snippets)))
      (when snippet
        (with-current-buffer (get-buffer-create "*Yankpad Doc*")
          (erase-buffer)
          (insert (format "Snippet: %s\n\n" (car snippet)))
          (let ((snippet-text (yankpad-snippet-text snippet)))
            (when snippet-text
              (insert "Content:\n")
              (insert snippet-text)
              (insert "\n\n")))
          (when (> (length snippet) 1)
            (insert "Additional details:\n")
            (dolist (detail (cdr snippet))
              (insert (format "- %S\n" detail))))
          (goto-char (point-min))
          (current-buffer))))))

;;;###autoload
(defun yankpad-capf ()
  "Completion-at-point function for Yankpad with advanced support."
  (interactive)
  (when (and (featurep 'yankpad) yankpad-file)
    (let* ((bounds (or (bounds-of-thing-at-point 'word) (cons (point) (point))))
           (start (car bounds))
           (end (cdr bounds))
           (prefix (buffer-substring-no-properties start end))
           (snippets (yankpad-active-snippets))
           (categories (yankpad--categories))
           (completions (yankpad--get-completion-candidates prefix snippets categories)))
      (when (and completions
                 (or (> (length prefix) 0)
                     (> (length completions) 0)))
        (list start end completions
              :annotation-function (lambda (candidate)
                                     (get-text-property 0 'annotation candidate))
              :company-kind (lambda (_) 'snippet)
              :company-doc-buffer #'yankpad--doc-buffer
              :exit-function (lambda (candidate status)
                               (when (string= status "finished")
                                 (let* ((current-point (point))
                                        (region-start (- current-point (length candidate))))
                                   (delete-region region-start current-point)
                                   (if (member candidate categories)
                                       (progn
                                         (insert candidate)
                                         (yankpad-set-category
                                          (substring-no-properties candidate))
                                         (message "Category changed to %s" candidate))
                                     (let* ((full-snippet-name
                                             (cl-find-if (lambda (snippet)
                                                           (string-prefix-p candidate (car snippet)))
                                                         snippets))
                                            (yankpad-snippet (assoc (car full-snippet-name) snippets)))
                                       (when yankpad-snippet
                                         (yankpad--run-snippet yankpad-snippet)))))))
              :exclusive 'yes)))))

(provide 'yankpad)
;;; yankpad.el ends here
