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

### 2. Set up `.env` (recommended — no more typing the token every run)

```powershell
git clone <this-repo-url>
cd Jira_Automator
copy .env.example .env
notepad .env
```

Fill in your values:

```dotenv
JIRA_SITE=https://your-domain.atlassian.net
JIRA_EMAIL=you@example.com
JIRA_API_TOKEN=your-api-token
```

`.env` is git-ignored (see `.gitignore`), so your token never gets committed.
There's deliberately no root issue key in `.env` — that's the one thing you
change on every run, so the script always asks for it instead of silently
reusing an old value.

### 3. Run it

**Double-click `Export-JiraTree.bat`** — it runs the script using `.env` for
site/email/token, then prompts you for the root issue key, and pauses at the
end so the window doesn't close before you can read the result. To skip the
prompt, pass the key as an argument (from a terminal):

```powershell
Export-JiraTree.bat KAN-183
```

Or run the PowerShell script directly:

```powershell
.\Export-JiraTree.ps1
```

`-RootIssue` is always prompted for unless passed as a parameter or bat file
argument. `-Site`/`-Email`/`-ApiToken` fall back to `.env`, and if still
missing, are prompted for too (the token prompt masks input) — so the script
also works with no `.env` set up at all:

```powershell
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
- Precedence for `-Site`/`-Email`/`-ApiToken` is: command-line parameter →
  `.env` → interactive prompt. `-RootIssue` skips the `.env` step and always
  prompts unless passed directly — e.g. exporting a different issue or site:

  ```powershell
  .\Export-JiraTree.ps1 -RootIssue "KAN-183"
  .\Export-JiraTree.ps1 -Site "https://another-domain.atlassian.net" -Email "you@example.com" -RootIssue "ABC-100"
  ```
