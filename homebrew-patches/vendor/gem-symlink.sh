#!/bin/sh
# Create vendor/bundle/ruby/3.4.0 -> 4.0.0 symlink
# Allows Ruby 3.4.9 to find vendored gems (sorbet-runtime etc.)
# Run from iSH Alpine host (not inside chroot)
BUNDLE=/mnt/debian/home/linuxbrew/.linuxbrew/Homebrew/Library/Homebrew/vendor/bundle/ruby
if [ ! -e "$BUNDLE/3.4.0" ]; then
    ln -s "$BUNDLE/4.0.0" "$BUNDLE/3.4.0"
    echo "OK: symlink created $BUNDLE/3.4.0 -> 4.0.0"
else
    echo "SKIP: $BUNDLE/3.4.0 already exists"
fi
