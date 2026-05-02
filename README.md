# tramp-proxy

An Emacs minor mode that proxies download commands (`git clone`, `wget`, `curl`) from local `eshell` to a remote server via TRAMP, syncing results back automatically.

## Why?

When your remote server has better bandwidth or network access than your local machine, `tramp-proxy` lets you leverage it for downloads while keeping your local directory structure intact.

## Installation

Add this directory to your `load-path` and require the package:

```elisp
(add-to-list 'load-path "/path/to/tramp-proxy")
(require 'tramp-proxy)
```

## Configuration

```elisp
(setq tramp-proxy-host "my-remote-server")
```

The host must be accessible via TRAMP (e.g., configured in `~/.ssh/config`).

### Optional Settings

```elisp
(setq tramp-proxy-remote-root "/tmp/tramp-proxy")  ; Remote working directory
(setq tramp-proxy-cleanup-remote t)                 ; Clean up remote files after sync
(setq tramp-proxy-transfer-method 'tramp)           ; Or 'rsync for large files
(setq tramp-proxy-fallback-on-error t)              ; Fall back to local execution on error
```

## Usage

### Transparent Mode (Minor Mode)

Enable `tramp-proxy-mode` in an `eshell` buffer. Supported commands are automatically intercepted:

```bash
$ tramp-proxy-mode
$ git clone https://github.com/user/repo.git
$ wget https://example.com/file.zip
$ curl -O https://example.com/file.zip
```

### Explicit Commands

Use explicit `proxy-*` commands without enabling the minor mode:

```bash
$ proxy-git clone https://github.com/user/repo.git
$ proxy-wget https://example.com/file.zip
$ proxy-curl -O https://example.com/file.zip
```

## How It Works

1. **Path Mapping**: Your local directory (`~/projects/`) is mapped to a deterministic remote path (`/tmp/tramp-proxy/home_user_projects/`)
2. **Pre-Sync**: Local context (e.g., `~/.gitconfig`) is pushed to the remote
3. **Execution**: The command runs on the remote via TRAMP with PTY allocation for progress bars
4. **Monitoring**: Output streams back to a local `term-mode` buffer in real time
5. **Post-Sync**: Results are copied from remote to local directory
6. **Cleanup**: Remote working files are removed (configurable)

## Architecture

```
tramp-proxy.el          Core engine, minor mode, eshell integration
tramp-proxy-utils.el    Path encoding, sync helpers, configuration
tramp-proxy-git.el      Git clone handler
tramp-proxy-download.el Wget and curl handlers
```

## Limitations

- **Transfer cost**: Results must be pulled back from the remote; large repos incur double network usage (remote download + sync back)
- **SSH keys**: `git clone` over SSH requires agent forwarding or deploy keys on the remote
- **Progress bar rendering**: `git clone` progress output uses `\r` (carriage return) to overwrite lines in place. The current `term-mode` + `term-line-mode` display does not fully clear old characters when the new progress text is shorter, so the log buffer may show overlapping fragments (e.g., `ResolvResolving deltas: ...`). This is a cosmetic issue in the display buffer — the download and sync work correctly


## License

GPL-3.0+
