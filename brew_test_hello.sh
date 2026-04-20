#!/bin/sh
# Test Homebrew install inside Debian chroot on iSH
# Run from iSH Alpine host after brew_apply_patches.sh
# Usage: sh /root/perplexity/brew_test_hello.sh
cd /
chroot /mnt/debian /bin/bash -c "
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
cd /root
brew install hello 2>&1
echo BREW_EXIT:\$?
"
