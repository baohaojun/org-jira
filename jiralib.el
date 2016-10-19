;;; jiralib.el -- Provide connectivity to JIRA SOAP service

;; Copyright (C) 2011 Bao Haojun
;; original Copyright (C) 2009 Alex Harsanyi

;; Also, used some code from jira.el, which use xml-rpc instead of soap.
;; Thus Copyright (C) for jira.el related code:
;; Brian Zwahr <echosa@gmail.com>
;; Dave Benjamin <dave@ramenlabs.com>

;; Authors:
;; Bao Haojun <baohaojun@gmail.com>
;; Alex Harsanyi <AlexHarsanyi@gmail.com>

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; Author: Alexandru Harsanyi (AlexHarsanyi@gmail.com)
;; Created: December, 2009
;; Package-Requires: ((request "0.2.0"))
;; Keywords: soap, web-services, jira
;; Homepage: http://code.google.com/p/emacs-soap-client

;;; Commentary:
;; This file provides a programatic interface to JIRA.  It provides access to
;; JIRA from other programs, but no user level functionality.

;; Jira References:
;;
;; http://confluence.atlassian.com/display/JIRA/Creating+a+SOAP+Client
;;
;; JavaDoc for the Jira SOAP service
;; http://docs.atlassian.com/software/jira/docs/api/rpc-jira-plugin/latest/com/atlassian/jira/rpc/soap/JiraSoapService.html

(eval-when-compile (require 'cl))
(require 'soap-client)
(require 'request)
(require 'json)
(require 'url-parse)

;;; Code:
(defgroup jiralib nil
  "Jiralib customization group."
  :group 'applications)

(defgroup jiralib-faces nil
  "Faces for displaying Jiralib information."
  :group 'jiralib)

(defcustom jiralib-use-restapi t
  "Use restapi instead of soap."
  :group 'jiralib
  :type 'boolean
  :initialize 'custom-initialize-set)

(defcustom jiralib-host ""
  "User customizable host name of the Jiralib server.

This will be used with USERNAME to compute password from
.authinfo file.  Will be calculated from jiralib-url if not set."
  :group 'jiralib
  :type 'string
  :initialize 'custom-initialize-set)

(defface jiralib-issue-info-face
  '((t (:foreground "black" :background "yellow4")))
  "Base face for issue information."
  :group 'jiralib-faces)

(defface jiralib-issue-info-header-face
  '((t (:bold t :inherit 'jiralib-issue-info-face)))
  "Base face for issue headers."
  :group 'jiralib-faces)

(defface jiralib-issue-summary-face
  '((t (:bold t)))
  "Base face for issue summary."
  :group 'jiralib-faces)

(defface jiralib-comment-face
  '((t (:background "gray23")))
  "Base face for comments."
  :group 'jiralib-faces)

(defface jiralib-comment-header-face
  '((t (:bold t)))
  "Base face for comment headers."
  :group 'jiralib-faces)

(defface jiralib-link-issue-face
  '((t (:underline t)))
  "Face for linked issues."
  :group 'jiralib-faces)

(defface jiralib-link-project-face
  '((t (:underline t)))
  "Face for linked projects"
  :group 'jiralib-faces)

(defface jiralib-link-filter-face
  '((t (:underline t)))
  "Face for linked filters"
  :group 'jiralib-faces)

(defvar jiralib-mode-hook nil)

(defvar jiralib-mode-map nil)

(defcustom jiralib-wsdl-descriptor-url
  ""
  "The location for the WSDL descriptor for the JIRA service.
This is specific to your local JIRA installation.  The URL is
tipically:

  http://YOUR_INSTALLATION/rpc/soap/jirasoapservice-v2?wsdl

The default value works if JIRA is located at a hostname named
'jira'."
  :type 'string
  :group 'jiralib)

(defcustom jiralib-url
  "http://localhost:8081/"
  "The address of the jira host."
  :type 'string
  :group 'jiralib)

(defvar jiralib-token nil
  "JIRA token used for authentication.")

(defvar jiralib-rest-auth-head nil
  "JIRA restapi auth head.")

(defvar jiralib-user-login-name nil
  "The name of the user logged into JIRA.
This is maintained by `jiralib-login'.")

(defvar jiralib-wsdl nil)

(defun jiralib-load-wsdl ()
  "Load the JIRA WSDL descriptor."
  (setq jiralib-wsdl (soap-load-wsdl-from-url (if (string-equal jiralib-wsdl-descriptor-url "")
                                                  (concat jiralib-url "/rpc/soap/jirasoapservice-v2?wsdl")
                                                jiralib-wsdl-descriptor-url))))

(defun jiralib-login (username password)
  "Login into JIRA as user USERNAME with PASSWORD.

After a succesful login, store the authentication token in
`jiralib-token'."
  ;; NOTE that we cannot rely on `jiralib-call' because `jiralib-call' relies on
  ;; us ;-)
  (interactive
   (if (> 24 emacs-major-version)
       (let ((user (read-string "Username for Jira server login? "))
             (password (read-passwd "Password for Jira server login? ")))
         (list user password))
     (let ((found (nth 0 (auth-source-search :max 1
                                             :host (if (string= jiralib-host "")
                                                       (url-host (url-generic-parse-url jiralib-url))
                                                     jiralib-host)
                                             :port (url-port (url-generic-parse-url jiralib-url))
                                             :require '(:user :secret)
                                             :create t)))
           user secret)
       (when found
         (setq user (plist-get found :user)
               secret
               (let ((sec (plist-get found :secret)))
                 (if (functionp sec)
                     (funcall sec)
                   sec)))
         (list user secret)))))
  (if jiralib-use-restapi
      (setq jiralib-token `("Authorization" . , (format "Basic %s" (base64-encode-string (concat username ":" password)))))
    (unless jiralib-wsdl
      (jiralib-load-wsdl))
    (setq jiralib-token
          (car (soap-invoke jiralib-wsdl "jirasoapservice-v2" "login" username password)))
    (setq jiralib-user-login-name username))
  ;; At this poing, soap-invoke didn't raise an error, so the login
  ;; credentials are OK.  use them to log into the web interface as
  ;; well, as this will be used to link issues (an operation which is
  ;; not exposed to the SOAP interface.
  ;;
  ;; Note that we don't validate the response at all -- not sure how we
  ;; would do it...
  (let ((url (concat jiralib-url "/secure/Dashboard.jspa?"
                     (format "&os_username=%s&os_password=%s&os_cookie=true"
                             username password))))
    (let ((url-request-method "POST")
          (url-package-name "Emacs jiralib.el")
          (url-package-version "1.0")
          (url-mime-charset-string "utf-8;q=1, iso-8859-1;q=0.5")
          (url-request-data "abc")
          (url-request-coding-system 'utf-8)
          (url-http-attempt-keepalives t))
      (let ((buffer (url-retrieve-synchronously url)))
        ;; This is just a basic check that the page was retrieved
        ;; correctly.  No error does not indicate a succesfull login,
        ;; we would have to parse the HTML page to find that out...
        (with-current-buffer buffer
          (declare (special url-http-response-status))
          (if (> url-http-response-status 299)
              (error "Error logging into JIRA Web interface %s"
                     url-http-response-status)))
        (kill-buffer buffer)))))

(defun jiralib-call (method &rest params)
  "Invoke the JIRA METHOD with supplied PARAMS.

This function should be used for all JIRA interface calls, as the
method ensures the user is logged in and invokes `soap-invoke'
with the correct service name and authentication token.

All JIRA inteface methods take an authentication token as the
first argument.  The authentication token is supplied by this
function, so PARAMS should omit this parameter.  For example, the
\"getIssue\" method takes two parameters: auth and key, however,
when invoking it through `jiralib-call', the call shoulbe be:

  (jiralib-call \"getIssue\" KEY)"
  (if (not jiralib-use-restapi)
      (car (apply 'jiralib--call-it method params))
    (unless jiralib-token
      (call-interactively 'jiralib-login))
    (case (intern method)
      ('getStatuses (jiralib--rest-call-it "/rest/api/2/status"))
      ('getIssueTypes (jiralib--rest-call-it "/rest/api/2/issuetype"))
      ('getUser (jiralib--rest-call-it "/rest/api/2/user" :params `((username . ,(first params)))))
      ('getVersions (jiralib--rest-call-it (format "/rest/api/2/project/%s/versions" (first params))))
      ('getWorklogs nil) ; fixme
      ('addComment (jiralib--rest-call-it
                    (format "/rest/api/2/issue/%s/comment" (first params))
                    :type "POST"
                    :data (json-encode (second params))))
      ('createIssue (jiralib--rest-call-it
                     "/rest/api/2/issue"
                     :type "POST"
                     :data (json-encode (first params))))
      ('createIssueWithParent (jiralib--rest-call-it
                               ))
      ('editComment (jiralib--rest-call-it
                     (format "/rest/api/2/issue/%s/comment/%s" (first params) (second params))
                     :data (json-encode `((body . ,(third params))))
                     :type "PUT"))
      ('getComments (org-jira-find-value (jiralib--rest-call-it
                                          (format "/rest/api/2/issue/%s/comment" (first params))) 'comments))
      ('getComponents (jiralib--rest-call-it
                       (format "/rest/api/2/project/%s/components" (first params))))
      ('getIssue (jiralib--rest-call-it
                  (format "/rest/api/2/issue/%s" (first params))))
      ('getIssuesFromJqlSearch  (append (cdr ( assoc 'issues (jiralib--rest-call-it
                                                              "/rest/api/2/search"
                                                              :type "POST"
                                                              :data (json-encode `((jql . ,(first params))
                                                                                   (maxResults . ,(second params))))))) nil))
      ('getPriorities (jiralib--rest-call-it
                       "/rest/api/2/priority"))
      ('getProjectsNoSchemes (append (jiralib--rest-call-it
                                      "/rest/api/2/project"
                                      :params '((expand . "description,lead,url,projectKeys"))) nil))
      ('getResolutions (append (jiralib--rest-call-it
                                "/rest/api/2/resolution") nil))
      ('getAvailableActions (mapcar (lambda (trans) `(,(assoc 'name trans) ,(assoc 'id trans)))
                                    (append (let* ((iss  (first params))
                                                   (data (jiralib--rest-call-it
                                                          (format "/rest/api/2/issue/%s/transitions" (first params))))
                                                   (transitions (cdr (assoc 'transitions data))))
                                              transitions)
                                            nil)))
      ('getFieldsForAction (org-jira-find-value
                            (car (let ((issue (first params))
                                       (action (second params)))
                                   (seq-filter (lambda (trans)
                                                 (or (string-equal action (org-jira-find-value trans 'id))
                                                     (string-equal action (org-jira-find-value trans 'name))))
                                               (cdr (assoc 'transitions (jiralib--rest-call-it
                                                                         (format "/rest/api/2/issue/%s/transitions" (first params))
                                                                         :params '((expand . "transitions.fields"))))))))
                            'fields))
      ('progressWorkflowAction (jiralib--rest-call-it
                                (format "/rest/api/2/issue/%s/transitions" (first params))
                                :parser "none"
                                :type "POST"
                                :data (json-encode `(,(car (second params)) ,(car (third params))))))
      ('updateIssue (jiralib--rest-call-it
                     (format "/rest/api/2/issue/%s" (first params))
                     :type "PUT"
                     :data (json-encode `((fields . ,(second params)))))))))

(defun jiralib--soap-call-it (&rest args)
  (let ((jiralib-token nil)
        (jiralib-use-restapi nil)) (apply #'jiralib-call args)))

(defun jiralib--rest-call-it (api &rest args)
  "Invoke the corresponding jira rest method API, passing ARGS to REQUEST."
  (append (request-response-data
           (apply #'request (concat (replace-regexp-in-string "/*$" "/" jiralib-url)
                                    (replace-regexp-in-string "^/*" "" api))
                  :sync t
                  :headers `(,jiralib-token ("Content-Type" . "application/json"))
                  :parser (lambda ()
                            (let ((parser (plist-get args :parser)))
                              (unless (and (stringp parser)
                                           (string-equal "none" parser))
                                (if (or (and (symbolp parser)
                                             (fboundp parser))
                                        (functionp parser))
                                    (funcall parser)
                                  (json-read)))))
                  args)) nil))

(defun jiralib--call-it (method &rest params)
  "Invoke the JIRA METHOD with supplied PARAMS.

Internal use, returns a list of responses, of which only the
first is normally used."
  (when (symbolp method)
    (setq method (symbol-name method)))
  (unless jiralib-token
    (call-interactively 'jiralib-login))
  (condition-case data
      (apply 'soap-invoke jiralib-wsdl "jirasoapservice-v2"
             method jiralib-token params)
    (soap-error
     ;; If we are here, we had a token, but it expired.  Re-login and try
     ;; again.
     (setq jiralib-token nil)
     (call-interactively 'jiralib-login)
     (apply 'soap-invoke jiralib-wsdl "jirasoapservice-v2"
            method jiralib-token params))))


;;;; Some utility functions

(defun jiralib-make-list (data field)
  "Map all assoc elements in DATA to the value of FIELD in that element."
  (loop for element in data
        collect (cdr (assoc field element))))
(defun jiralib-make-assoc-list (data key-field value-field)
  "Create an association list from a SOAP structure array.

DATA is a list of association lists (a SOAP array-of type)
KEY-FIELD is the field to use as the key in the returned alist
VALUE-FIELD is the field to use as the value in the returned alist"
  (loop for element in data
        collect (cons (cdr (assoc key-field element))
                      (cdr (assoc value-field element)))))

(defun jiralib-make-remote-field-values (fields)
  "Transform the (KEY . VALUE) list FIELDS into a RemoteFieldValue structure.

Each (KEY . VALUE) pair is transformed into
 ((id . KEY) (values . (VALUE)))

This method exists because Several JIRA methods require a
RemoteFieldValue list, but it is easier to work with ALISTS in
emacs-lisp"
  (let ((remote-field-values))

    ;; we accept an ALIST of field-name field-values parameter, but we need to
    ;; construct a structure that encodes as a RemoteFieldValue which is what
    ;; updateIssue wants
    (dolist (field fields)
      (let ((name (car field))
            (value (cdr field)))
        (when (symbolp name)
          (setq name (symbol-name name)))
        ;; Value must be an "array" (for which soap-client accepts lists) even
        ;; if it is just one value
        (unless (vectorp value)
          (setq value (vector value)))
        (push `((id . ,name) (values . ,value))
              remote-field-values)))

    (apply 'vector (nreverse remote-field-values))))

;;;; Wrappers around JIRA methods

(defun jiralib--rest-api-for-issue-key (key)
  "Return jira rest api for issue KEY."
  (concat "rest/api/2/issue/" key))

(defun jiralib-update-issue (key fields)
  "Update the issue with id KEY with the values in FIELDS."

  (jiralib-call "updateIssue" key (if jiralib-use-restapi
                                      fields
                                    (jiralib-make-remote-field-values fields))))


(defvar jiralib-status-codes-cache nil)

(defun jiralib-get-statuses ()
  "Return an assoc list mapping a status code to its name.
NOTE: Status codes are stored as strings, not numbers.

This function will only ask JIRA for the list of codes once, then
will cache it."
  (unless jiralib-status-codes-cache
    (setq jiralib-status-codes-cache
          (jiralib-make-assoc-list (jiralib-call "getStatuses") 'id 'name)))
  jiralib-status-codes-cache)

(defvar jiralib-issue-types-cache nil)

(defun jiralib-get-issue-types ()
  "Return an assoc list mapping an issue type code to its name.
NOTE: Issue type codes are stored as strings, not numbers.

This function will only ask JIRA for the list of codes once, than
will cache it."
  (unless jiralib-issue-types-cache
    (setq jiralib-issue-types-cache
          (jiralib-make-assoc-list (jiralib-call "getIssueTypes") 'id 'name)))
  jiralib-issue-types-cache)

(defvar jiralib-priority-codes-cache nil)

(defun jiralib-get-priorities ()
  "Return an assoc list mapping a priority code to its name.
NOTE: Priority codes are stored as strings, not numbers.

This function will only ask JIRA for the list of codes once, than
will cache it."
  (unless jiralib-priority-codes-cache
    (setq jiralib-priority-codes-cache
          (jiralib-make-assoc-list (jiralib-call "getPriorities") 'id 'name)))
  jiralib-priority-codes-cache)

(defvar jiralib-resolution-code-cache nil)

(defun jiralib-get-resolutions ()
  "Return an assoc list mapping a resolution code to its name.
NOTE: Resolution codes are stored as strings, not numbers.

This function will only ask JIRA for the list of codes once, than
will cache it."
  (unless jiralib-resolution-code-cache
    (setq jiralib-resolution-code-cache
          (jiralib-make-assoc-list (jiralib-call "getResolutions") 'id 'name)))
  jiralib-resolution-code-cache)

(defvar jiralib-issue-regexp nil)

;; NOTE: it is not such a good ideea to use this, as it needs a JIRA
;; connection to construct the regexp (the user might be prompted for a JIRA
;; username and password).
;;
;; The best use of this function is to generate the regexp once-off and
;; persist it somewhere.

(defun jiralib-get-issue-regexp ()
  "Return a regexp that will match an issue id.

The regexp is constructed from the project keys in the JIRA
database.  An issue is assumed to be in the format KEY-NUMBER,
where KEY is a project key and NUMBER is the issue number."
  (unless jiralib-issue-regexp
    (let ((projects (mapcar (lambda (e) (downcase (cdr (assoc 'key e))))
                            (jiralib-call "getProjectsNoSchemes"))))
      (setq jiralib-issue-regexp (concat "\\<" (regexp-opt projects) "-[0-9]+\\>"))))
  jiralib-issue-regexp)

(defun jiralib-do-jql-search (jql &optional limit)
  "Run a JQL query and return the list of issues that matched.
LIMIT is the maximum number of queries to return.  Note that JIRA
has an internal limit of how many queries to return, as such, it
might not be possible to find *ALL* the issues that match a
query."
  (unless (or limit (numberp limit))
    (setq limit 100))
  (jiralib-call "getIssuesFromJqlSearch" jql limit))

(defun jiralib-get-available-actions (issue-key)
  "Return the available workflow actions for ISSUE-KEY.
This runs the getAvailableActions SOAP method."
  (jiralib-make-assoc-list
   (jiralib-call "getAvailableActions" issue-key)
   'id 'name))

(defun jiralib-get-fields-for-action (issue-key action-id)
  "Return the required fields to change ISSUE-KEY to ACTION-ID."
  (if jiralib-use-restapi
      (let ((fields (jiralib-call "getFieldsForAction" issue-key action-id)))
        (mapcar (lambda (field)
                  (cons (symbol-name (car field)) (format "%s (required: %s)"
                                                          (org-jira-find-value field 'name)
                                                          (if (eq (org-jira-find-value field 'required) :json-false)
                                                              "nil"
                                                            "t")))) fields))
    (jiralib-make-assoc-list
     (jiralib-call "getFieldsForAction" issue-key action-id)
     'id 'name)))

(defun jiralib-progress-workflow-action (issue-key action-id params)
  "Progress issue with ISSUE-KEY to action ACTION-ID, and provide the needed PARAMS."
  (if jiralib-use-restapi
      (jiralib-call "progressWorkflowAction" issue-key `((transition (id . ,action-id)))
                    `((fields . ,params)))
    (jiralib-call "progressWorkflowAction" issue-key action-id (jiralib-make-remote-field-values params))))

(defun jiralib-add-worklog-and-autoadjust-remaining-estimate (issue-key start-date time-spent comment)
  "Log time spent on ISSUE-KEY to its worklog.
The time worked begins at START-DATE and has a TIME-SPENT
duration.  JIRA will automatically update the remaining estimate
by subtracting TIME-SPENT from it.

START-DATE should be in the format 2010-02-05T14:30:00Z

TIME-SPENT can be in one of the following formats: 10m, 120m
hours; 10h, 120h days; 10d, 120d weeks.

COMMENT will be added to this worklog."
  (jiralib-call "addWorklogAndAutoAdjustRemainingEstimate"
                issue-key
                `((startDate . ,start-date)
                  (timeSpent . ,time-spent)
                  (comment   . ,comment))))

(defun jiralib-link-issue (issue-key link-type other-issue-key)
  "Link ISSUE-KEY with a link of type LINK-TYPE to OTHER-ISSUE-KEY.
LINK-TYPE is a string representing the type of the link, e.g
\"requires\", \"depends on\", etc.  I believe each JIRA
installation can define its own link types."

  ;; IMPLEMENTATION NOTES: The linking jira issues functionality is
  ;; not exposed through the SOAP api, we must use the web interface
  ;; to do the linking.  Unfortunately, we cannot parse the result, so
  ;; we don't know that the linking was succesfull or not.  To reduce
  ;; the risk, we use the SOAP api to retrieve the issues for
  ;; ISSUE-KEY and OTHER-ISSUE-KEY.  This will ensure that we are
  ;; logged in (see also jiralib-login) and that both issues exist. We
  ;; don't validate the LINK-TYPE, not sure how to do it.

  (let ((issue (jiralib-get-issue issue-key))
        (other-issue (jiralib-get-issue other-issue-key)))
    (let ((url (concat jiralib-url
                       "/secure/LinkExistingIssue.jspa?"
                       (format "linkDesc=%s&linkKey=%s&id=%s&Link=Link"
                               link-type other-issue-key (cdr (assq 'id issue))))))
      (let ((url-request-method "POST")
            (url-package-name "Emacs scratch.el")
            (url-package-version "1.0")
            (url-mime-charset-string "utf-8;q=1, iso-8859-1;q=0.5")
            (url-request-data "abc")
            (url-request-coding-system 'utf-8)
            (url-http-attempt-keepalives t)
            ;; see http://confluence.atlassian.com/display/JIRA/Form+Token+Handling
            (url-request-extra-headers '(("X-Atlassian-Token" . "no-check"))))

        (let ((buffer (url-retrieve-synchronously url)))
          ;; This is just a basic check that the page was retrieved
          ;; correctly.  No error does not indicate a success as we
          ;; have to parse the HTML page to find that out...
          (with-current-buffer buffer
            (declare (special url-http-response-status))
            (if (> url-http-response-status 299)
                (error "Error linking issue through JIRA Web interface %s"
                       url-http-response-status)))
          (kill-buffer buffer))))))


;;;; Issue field accessors

(defun jiralib-issue-key (issue)
  "Return the key of ISSUE."
  (cdr (assoc 'key issue)))

(defun jiralib-issue-owner (issue)
  "Return the owner of ISSUE."
  (cdr (assq 'assignee issue)))

(defun jiralib-issue-status (issue)
  "Return the status of ISSUE as a status string (not as a number!)."
  (let ((status-code (cdr (assq 'status issue))))
    (cdr (assoc status-code (jiralib-get-statuses)))))

(defun jiralib-custom-field-value (custom-field issue)
  "Return the value of CUSTOM-FIELD for ISSUE.
Return nil if the field is not found"
  (catch 'found
    (dolist (field (cdr (assq 'customFieldValues issue)))
      (when (equal (cdr (assq 'customfieldId field)) custom-field)
        (throw 'found (cadr (assq 'values field)))))))

(defvar jiralib-current-issue nil
  "This holds the currently selected issue.")

(defvar jiralib-projects-list nil
  "This holds a list of projects and their details.")

(defvar jiralib-types nil
  "This holds a list of issues types.")

(defvar jiralib-priorities nil
  "This holds a list of priorities.")

(defvar jiralib-user-fullnames nil
  "This holds a list of user fullnames.")

(defun jiralib-get-project-name (key)
  "Return the name of the JIRA project with id KEY."
  (let ((projects jiralib-projects-list)
        (name nil))
    (dolist (project projects)
      (if (equal (cdr (assoc 'key project)) key)
          (setf name (cdr (assoc 'name project)))))
    name))

(defun jiralib-get-type-name (id)
  "Return the name of the issue type with ID."
  (let ((types jiralib-types)
        (name nil))
    (dolist (type types)
      (if (equal (cdr (assoc 'id type)) id)
          (setf name (cdr (assoc 'name type)))))
    name))

(defun jiralib-get-user-fullname (username)
  "Return the full name (display name) of the user with USERNAME."
  (if (assoc username jiralib-user-fullnames)
      (cdr (assoc username jiralib-user-fullnames))
    (progn
      (let ((user (jiralib-get-user username)))
        (setf jiralib-user-fullnames (append jiralib-user-fullnames (list (cons username (cdr (assoc 'fullname user))))))
        (cdr (assoc 'fullname user))))))


(defun jiralib-get-filter (filter-id)
  "Return a filter given its FILTER-ID."
  (cl-flet ((id-match (filter)
                      (equal filter-id (cdr (assoc 'id filter)))))
    (cl-find-if 'id-match (jiralib-get-saved-filters))))

(defun jiralib-get-filter-alist ()
  "Return an association list mapping filter names to IDs."
  (mapcar (lambda (filter)
            (cons (cdr (assoc 'name filter))
                  (cdr (assoc 'id filter))))
          (jiralib-get-saved-filters)))

(defun jiralib-add-comment (issue-key comment)
  "Add to issue with ISSUE-KEY the given COMMENT."
  (jiralib-call "addComment" issue-key `((body . ,comment))))

(defun jiralib-edit-comment (issue-id comment-id comment)
  "Edit ISSUE-ID's comment COMMENT-ID to reflect the new COMMENT."
  (if (not jiralib-use-restapi)
      (jiralib-call "editComment" `((id . ,comment-id)
                                    (body . ,comment)))
    (jiralib-call "editComment" issue-id comment-id comment)))

(defun jiralib-create-issue (issue)
  "Create a new ISSUE in JIRALIB.

ISSUE is a Hashtable object."
  (jiralib-call "createIssue" issue))

(defun jiralib-create-subtask (subtask parent-issue-id)
  "Create SUBTASK for issue with PARENT-ISSUE-ID.

SUBTASK is a Hashtable object."
  (jiralib-call "createIssueWithParent" subtask parent-issue-id))


(defvar jiralib-subtask-types-cache nil)

(defun jiralib-get-subtask-types ()
  "Return an assoc list mapping an issue type code to its name.
NOTE: Issue type codes are stored as strings, not numbers.

This function will only ask JIRA for the list of codes once, than
will cache it."
  (unless jiralib-subtask-types-cache
    (setq jiralib-subtask-types-cache
          (jiralib-make-assoc-list (jiralib-call "getSubTaskIssueTypes") 'id 'name)))
  jiralib-subtask-types-cache)


(defun jiralib-get-comments (issue-key)
  "Return all comments associated with issue ISSUE-KEY."
  (jiralib-call "getComments" issue-key))

(defun jiralib-get-worklogs (issue-key)
  "Return all worklogs associated with issue ISSUE-KEY."
  (jiralib-call "getWorklogs" issue-key))

(defun jiralib-update-worklog (worklog)
  "Update the WORKLOG, updating the ETA for the related issue."
  (jiralib-call "updateWorklogAndAutoAdjustRemainingEstimate" worklog))

(defun jiralib-get-components (project-key)
  "Return all components available in the project PROJECT-KEY."
  (jiralib-make-assoc-list (jiralib-call "getComponents" project-key) 'id 'name))

(defun jiralib-get-issue (issue-key)
  "Get the issue with key ISSUE-KEY."
  (jiralib-call "getIssue" issue-key))

(defun jiralib-get-issues-from-filter (filter-id)
  "Get the issues from applying saved filter FILTER-ID."
  (jiralib-call "getIssuesFromFilter" filter-id))

(defun jiralib-get-issues-from-text-search (search-terms)
  "Find issues using free text search SEARCH-TERMS."
  (jiralib-call "getIssuesFromTextSearch" search-terms))

(defun jiralib-get-issues-from-text-search-with-project
    (project-keys search-terms max-num-results)
  "Find issues in projects PROJECT-KEYS, using free text search SEARCH-TERMS.

Return no more than MAX-NUM-RESULTS."
  (jiralib-call "getIssuesFromTextSearchWithProject"
                (apply 'vector project-keys) search-terms max-num-results))

;; Modified by Brian Zwahr to use getProjectsNoSchemes instead of getProjects
(defun jiralib-get-projects ()
  "Return a list of projects available to the user."
  (if jiralib-projects-list
      jiralib-projects-list
    (setq jiralib-projects-list
          (if (not jiralib-use-restapi)
              (jiralib-call "getProjectsNoSchemes")
            (jiralib--rest-call-it "rest/api/2/project")))))

(defun jiralib-get-saved-filters ()
  "Get all saved filters available for the currently logged in user."
  (jiralib-make-assoc-list (jiralib-call "getSavedFilters") 'id 'name))

(defun jiralib-get-server-info ()
  "Return the Server information such as baseUrl, version, edition, buildDate, buildNumber."
  (jiralib-call "getServerInfo"))

(defun jiralib-get-sub-task-issue-types ()
  "Return all visible subtask issue types in the system."
  (jiralib-call "getSubTaskIssueTypes"))

(defun jiralib-get-user (username)
  "Return a user's information given their USERNAME."
  (jiralib-call "getUser" username))

(defun jiralib-get-versions (project-key)
  "Return all versions available in project PROJECT-KEY."
  (jiralib-call "getVersions" project-key))

(defun jiralib-strip-cr (string)
  "Remove carriage returns from STRING."
  (when string (replace-regexp-in-string "\r" "" string)))

(provide 'jiralib)
;;; jiralib.el ends here
