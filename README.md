# GH Actions Bar

A tiny macOS menu bar app that shows GitHub Actions status across **all** your repos: your own, ones you collaborate on, and every org you belong to.

- 🔴 / 🟡 / 🟢 dot in the menu bar: anything failing, running (with a count), or all green
- Dropdown lists repos with recent runs. Failing and running repos are listed first.
- Hover a repo to see its latest run per workflow and branch. Click a run to open it on GitHub.
- Refreshes every 60s, or every 15s while something is running. ⌘R refreshes now.

## Install

Requires macOS 13+ and the [GitHub CLI](https://cli.github.com), signed in:

```sh
brew install gh
gh auth login
```

Then download the latest `GHActionsBar-*.zip` from [Releases](https://github.com/drfarr/gh-actions-bar/releases), unzip it, and drag **GH Actions Bar.app** into Applications.

### First launch (unsigned build)

This release isn't notarised by Apple yet, so macOS blocks it the first time. Do either:

- **Terminal:** `xattr -dr com.apple.quarantine "/Applications/GH Actions Bar.app"`, then open it normally, **or**
- Open it once, dismiss the warning, then go to **System Settings → Privacy & Security** and click **Open Anyway**.

You only need to do this once. To start it at login: System Settings → General → Login Items → **+**.

The app uses your existing `gh` login. It never stores a token itself.

## Settings

Only repos pushed in the last 14 days are polled (max 40), which keeps you well inside GitHub's API rate limit. To change that:

```sh
defaults write com.drfarr.ghactionsbar days 30
defaults write com.drfarr.ghactionsbar maxRepos 60
```

Changes take effect on the next refresh.

## Build from source

```sh
./build.sh            # builds GH Actions Bar.app here
./build.sh --install  # also copies it to ~/Applications
./release.sh 0.1.0    # signs, notarises and zips a release (needs a Developer ID)
# Unsigned release zip:
./build.sh && ditto -c -k --keepParent "GH Actions Bar.app" GHActionsBar-0.1.0.zip
```
