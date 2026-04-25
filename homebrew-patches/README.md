# Homebrew iSH Compatibility Patches

Makes Homebrew work inside a Debian Bullseye chroot on **iSH Alpine Linux** (iPhone, kernel 4.20.69-i686, no jailbreak).

## The Problems

| Problem | Cause | Fix |
|---|---|---|
| `RuntimeError: must be run under Ruby 4.0` | `HOMEBREW_REQUIRED_RUBY_VERSION=4.0` vs our musl ruby 3.4.9 | Patch `standalone/init.rb` to override when >= 4 |
| `cannot load such file -- sorbet-runtime` | Vendored gems at `vendor/bundle/ruby/4.0.0/` not found by Ruby 3.x | Symlink `ruby/3.4.0 -> ruby/4.0.0` |
| `getcwd() failed: Bad file descriptor` | `bash -p` reinitializes env and calls `getcwd()` which fails in chroot | Remove `-p` from all shim shebangs |
| `/dev/fd/63: No such file or directory` | `< <(cmd)` bash process substitution needs `/dev/fd` — not available on iSH | Replace with `<<< "$(cmd)"` in `utils.sh` |
| `curl terminated by signal SYS` | Chroot's `/usr/bin/curl` is glibc — hits unsupported iSH syscalls | Wrap Alpine musl curl via `ld-musl-1.2.6-i386.so.1` |

## Quick Apply

From iSH Alpine host (NOT inside chroot):

```sh
# One-shot: apply all patches
sh /root/perplexity/brew_apply_patches.sh

# Then test
sh /root/perplexity/brew_test_hello.sh
```

Both scripts are in the repo root.

## Required brew env vars

```sh
export PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin
export HOME=/root
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew
export HOMEBREW_CELLAR=/home/linuxbrew/.linuxbrew/Cellar
export HOMEBREW_REPOSITORY=/home/linuxbrew/.linuxbrew/Homebrew
export HOMEBREW_GIT_PATH=/usr/local/bin/git
export HOMEBREW_RUBY_PATH=/usr/local/bin/ruby
export HOMEBREW_DEVELOPER=1
export HOMEBREW_USE_RUBY_FROM_PATH=1
export GEM_PATH=/home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle/ruby/3.4.0
export BUNDLE_PATH=/home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle
export HOMEBREW_CURL=/usr/local/bin/curl
export HOMEBREW_FORCE_BREWED_CURL=1
```

Also **always** `cd /` before calling `chroot` to avoid inheriting a bad working directory.

## Patch Files in This Directory

```
homebrew-patches/
├── README.md                       — this file
├── standalone/
│   └── init.rb.patch               — Ruby version override patch
├── shims/
│   ├── utils.sh.patch              — process substitution fix
│   └── shebang-p.patch             — bash -p removal (curl, git, svn)
├── vendor/
│   └── gem-symlink.sh              — creates 3.4.0 -> 4.0.0 symlink
└── curl-wrapper/
    └── setup-musl-curl.sh          — copies Alpine curl + libs into chroot
```

## After `brew update`

`brew update` may overwrite patched files. Re-run:

```sh
sh /root/perplexity/brew_apply_patches.sh
```

## Chroot Run Command (Full)

```sh
cd /
chroot /mnt/debian /bin/bash -c "
  export PATH=/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin
  export HOME=/root
  export HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
  export HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTO_UPDATE=1
  export HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew
  export HOMEBREW_CELLAR=/home/linuxbrew/.linuxbrew/Cellar
  export HOMEBREW_REPOSITORY=/home/linuxbrew/.linuxbrew/Homebrew
  export HOMEBREW_GIT_PATH=/usr/local/bin/git
  export HOMEBREW_RUBY_PATH=/usr/local/bin/ruby
  export HOMEBREW_DEVELOPER=1
  export HOMEBREW_USE_RUBY_FROM_PATH=1
  export GEM_PATH=/home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle/ruby/3.4.0
  export BUNDLE_PATH=/home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle
  export HOMEBREW_CURL=/usr/local/bin/curl
  export HOMEBREW_FORCE_BREWED_CURL=1
  brew install <package>
"
```

## Status

- `brew --version`  works
- `brew install hello` — pending tunnel recovery to confirm
