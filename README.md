# GodsView

A native macOS inbox for pull requests across your GitHub CLI accounts. Pick an account in the sidebar or see them together. Each PR keeps its account identity through to the comment composer.

![GodsView workspace showing a review queue and selected pull request with example data](docs/workspace.png)

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

If you already use `gh`, GodsView discovers your existing accounts. To connect another identity, repeat the login command and refresh with **⌘R**. You can move the built app to Applications.

## Using the inbox

- Choose **Review requests**, **Authored by me**, or **Assigned to me**. A PR matching several queues appears once per account in the combined inbox.
- Press **⌘F** to filter by title, repository, author, account, or PR number. Search and queue changes operate on the loaded inbox.
- Select a PR to inspect its description, review decision, branches, labels, and change totals. **Discussion** loads the latest 20 conversation comments.
- Bookmark a PR to find it under **Saved** while it is in your open inbox. **Comment** shows the posting identity and accepts GitHub Markdown.
- Each refresh loads up to 50 recently updated open PRs per queue per account. The footer indicates when GitHub has more results. Click the external-link icon to open the full PR.

## Development

```sh
swift run GodsView
swift test
swift test -c release
```

The SwiftUI workspace and account state live in `Sources/GodsView`. `Sources/GitHubCore` owns GitHub CLI execution, per-account authentication, and API decoding. Account requests run concurrently. Each request obtains its credential from `gh` and passes it through the child process environment. The app keeps PR content in memory and stores saved PR identifiers in macOS preferences. Your global CLI account selection stays intact.

The compact PR rows and separation of list presentation from data loading were informed by [T3 Code](https://github.com/pingdotgg/t3code).
