# GodsView

A native macOS inbox for pull requests across your GitHub CLI accounts. Pick an account in the sidebar or see them together. Each PR keeps its account identity through to the comment composer.

![GodsView workspace showing a changed-file tree and commit-aware diff viewer with example data](docs/workspace.png)

## Run on macOS

Requires macOS 14 or later, a current version of [GitHub CLI](https://cli.github.com/), and a GitHub.com login. To build from source, install Xcode 16 or newer, or its Command Line Tools with Swift 6.

```sh
brew install gh
gh auth login --hostname github.com --web
git clone https://github.com/yagyesh-bobde/godsview.git
cd godsview
./scripts/build-app.sh
open dist/GodsView.app
```

If you already use `gh`, GodsView discovers your existing accounts. To connect another identity, repeat the login command and choose **Workspace → Refresh Inbox**. You can move the built app to Applications.

## Using the inbox

- Choose **Review requests**, **Authored by me**, or **Assigned to me**. A PR matching several queues appears once per account in the combined inbox.
- The sidebar groups PRs by repository. Filter by title, repository, author, account, or PR number.
- Select a PR to inspect its description, review decision, branches, labels, and change totals. **Summary** and **Discussion** render GitHub Markdown. Discussion shows the latest 20 conversation comments and keeps the last conversation visible during refresh.
- Bookmark a PR to find it under **Saved** while it is in your open inbox. **Comment** shows the posting identity and accepts GitHub Markdown.
- Each refresh loads up to 50 recently updated open PRs per queue per account. The footer indicates when GitHub has more results. Click the external-link icon to open the full PR.

## Reviewing code

The native title bar shows the repository and current PR. Open the title menu to switch PRs within that repository.

The **Code** tab opens with the PR diff and its changed-file tree. Scroll continuously through every changed file. Click a file header to fold its patch, or use **Collapse all** and **Expand all**. Selecting a path in the tree or palette expands it and scrolls it into view. The PR header folds as you scroll down and returns at the top. Use its chevron for manual control. Use **File** to read the complete UTF-8 blob for that revision, including the previous blob for deleted files when available. For an omitted text patch, **Load diff** compares the Git blobs against the PR merge base or the selected commit’s first parent. The generated patch opens inline and is cached. GitHub limits a PR or commit file listing to 3,000 entries.

**⌘R** reloads GodsView from its installed bundle. It restores your PR, tab, commit, file, and filters, then checks GitHub for updated revisions. Use the sidebar refresh button to sync just the inbox. GodsView restores the previous inbox and selection on launch, then checks GitHub in the background. It checks again every three minutes while the workspace is open and when you return after a minute. An offline account keeps its last successful results. Changed-file lists and diffs are reused for the same account and revisions.

Choose **All commits** above the diff to search the PR history by message or SHA. Picking a commit shows its changes against its parent. The arrows beside the selector step through the history, retaining the selected path when it exists in the next commit.

| Shortcut | Action |
| --- | --- |
| ⌘K or ⇧⌘F | Search loaded PRs across accounts, commands, and the current review's paths and commits |
| ⌃⌥K | Bring GodsView forward and open search from another app while GodsView is running and the shortcut is available |
| ⌘P | Jump to a changed file in the current diff |
| ⇧⌘O | Search or switch commits |
| ⌥⌘← / ⌥⌘→ | Previous / next commit |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next changed file |
| ⌘F | Find text inside the current patch or full file |
| ⇧⌘Return | Enter or leave the full-screen file viewer |
| ⌘R | Reload the app and restore the current review |
| ⌘B | Toggle the PR sidebar |
| ⌘L | Toggle the Changed files sidebar |
| Hold ⌘, then press 1–9 | Show numbered hints and open the corresponding visible PR |

In a search palette, use the arrow keys to select, Return to open, and Escape to dismiss. The file-tree button also works in full-screen mode.

## Linear

Open **GodsView → Settings** (**⌘,**) or the sidebar gear, turn on **Linear MCP**, and enter the Streamable HTTP URL of your connected Linear MCP server or local bridge. **Test connection** checks whether it advertises the issue lookup tool. Summary shows the title, status, and link for issue IDs found in the PR title, source branch, or description. Linear is opt-in per installation.

## Development

```sh
swift run GodsView
swift test
swift test -c release
```

The SwiftUI workspace and account state live in `Sources/GodsView`. `Sources/GitHubCore` owns GitHub CLI execution, per-account authentication, and API decoding. Account requests run concurrently. Each request obtains its credential from `gh` and passes it through the child process environment. The app stores the inbox, conversations, and recently viewed diffs in the user’s macOS Caches directory. Full-file blobs stay in memory. Preferences hold saved PR identifiers, the last selection, and integration settings. Your global CLI account selection stays intact.

The repository sidebar, tabbed PR workspace, right-hand file tree, commit scope, and command palette follow the desktop review layout in [T3 Code](https://github.com/pingdotgg/t3code).
