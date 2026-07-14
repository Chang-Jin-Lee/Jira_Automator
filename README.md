# Jira Automator

`Export-JiraTree.ps1` recursively exports a Jira issue and every descendant
subtask/child issue (children of children, all the way down) into a single
Markdown, HTML, and JSON file. Useful for handing a whole task tree to an LLM,
archiving a sprint, or generating a quick shareable summary of a feature.

## Example output

See [`examples/KAN-182.md`](examples/KAN-182.md) / [`.html`](examples/KAN-182.html) / [`.json`](examples/KAN-182.json)
for a real export of a task tree with several subtasks.

## Setup

### 1. Create an Atlassian API token

1. Go to your Atlassian account → **Security** → **Create and manage API tokens** → **Create API token**
   (directly: https://id.atlassian.com/manage-profile/security/api-tokens)
2. Name it something like `jira-export` and copy the token — it's only shown once.

Authentication uses your Atlassian **email + API token**, never your account password.

### 2. Run the script

```powershell
git clone <this-repo-url>
cd Jira_Automator

.\Export-JiraTree.ps1 `
    -Site "https://your-domain.atlassian.net" `
    -Email "you@example.com" `
    -RootIssue "KAN-182"
```

You'll be prompted for the API token (input is masked). Any parameter you omit
(`-Site`, `-Email`, `-RootIssue`) will be prompted for interactively too, so
you can also just run `.\Export-JiraTree.ps1` with no arguments.

To skip the interactive token prompt (e.g. for repeated runs), set an
environment variable instead:

```powershell
$env:JIRA_API_TOKEN = "your-token"
.\Export-JiraTree.ps1 -Site "https://your-domain.atlassian.net" -Email "you@example.com" -RootIssue "KAN-182"
```

### If PowerShell blocks the script

This only happens with files downloaded via a browser (they get an
"unblock" flag). Cloning this repo with `git` does not trigger it. If you see
*"is not digitally signed"*, run:

```powershell
Unblock-File -Path .\Export-JiraTree.ps1
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

## Output

Running the script produces, in `.\jira-export\` by default (`-OutputDirectory` to change it):

```
jira-export/
├─ KAN-182.md
├─ KAN-182.html
└─ KAN-182.json
```

Each issue in the tree records: key, title, description, issue type, status,
assignee, priority, and Jira URL. Rich-text descriptions (Atlassian Document
Format) are converted to plain text, preserving lists, line breaks, and basic
table structure.

The default output directory (`jira-export/`) is git-ignored since it holds
your own Jira data — commit exports intentionally if you want to keep one
(as done in `examples/`).

## Notes

- Uses the Jira Cloud REST API v3 (`/rest/api/3/issue/{key}`) and the current
  JQL search endpoint (`/rest/api/3/search/jql`); the older `/search` endpoint
  is being deprecated by Atlassian.
- What the script can read is limited to what your Atlassian account can see
  in the Jira UI. A 401 means bad email/token; a 404 (or permission error)
  means you can't view that issue.
- Requests are automatically retried with backoff if Jira rate-limits (HTTP 429).

## Exporting a different issue or site

```powershell
.\Export-JiraTree.ps1 -Email "you@example.com" -RootIssue "KAN-183"

.\Export-JiraTree.ps1 -Site "https://another-domain.atlassian.net" -Email "you@example.com" -RootIssue "ABC-100"
```
