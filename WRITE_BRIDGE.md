# iSH Write Bridge

A small workaround for getting writes from Alpine inside iSH back out into
iOS so other apps (Files, Shortcuts, editors) can read them.

## The problem

iSH mounts the iOS file system under `/mnt/ios`. Many paths there look
read-write — including `/mnt/ios/private/var/tmp` and
`/mnt/ios/private/var/mobile/...` — but iOS sandboxing rejects the actual
write syscalls. You see things like:

```
$ : > /mnt/ios/private/var/tmp/x
sh: can't create /mnt/ios/private/var/tmp/x: Operation not permitted
```

A read-write *mount* is not the same as a writable *sandbox*. Outside of
the iSH app's own containers, iOS will refuse the write no matter how the
mount looks.

## The path that does work

The iSH app's shared app-group container:

```
/mnt/ios/private/var/mobile/Containers/Shared/AppGroup/<UUID>/
```

The iSH process owns this directory, so writes through it succeed and the
data lives in iOS (visible to the iSH "Files" provider, survives reboot,
etc).

The `<UUID>` is **device- and install-specific**. Do not hard-code it.
On one device it was `820760D6-304D-4560-BC27-022029AA8A9B`; on yours it
will be different. The setup script discovers it at runtime — by checking
the `/mnt/ios` mount source first, then by looking for an iSH-shaped
`roots/*/data` layout under each candidate UUID.

## Layout

The setup script creates this tree inside the discovered app-group dir:

```
PocketLabWriteBridge/
├── README.txt
├── inbox/    # files iOS / other apps drop here for Alpine to pick up
├── outbox/   # files Alpine produces for iOS / other apps to pick up
└── logs/     # long-running logs that should survive reboots
```

Plus convenience symlinks pointing at the bridge:

```
/root/ios-write           -> .../PocketLabWriteBridge
<repo>/ios-write          -> .../PocketLabWriteBridge   (if a repo is present)
```

Use `inbox`, `outbox`, `logs` as a small contract between scripts. Tools
that produce iOS-visible artifacts (reports, captured logs, exfil files)
should write under `outbox/` or `logs/` rather than `/tmp/`.

## Running it

On the iSH host shell:

```sh
sh ish/setup-write-bridge.sh
```

It will:

1. Discover the writable app-group UUID under
   `/mnt/ios/private/var/mobile/Containers/Shared/AppGroup`.
2. Create `PocketLabWriteBridge/{inbox,outbox,logs}` if missing.
3. Drop a `README.txt` describing the conventions.
4. (Re)create `/root/ios-write` and `<repo>/ios-write` symlinks.
5. Run a create / read / delete self-test and report success or failure.

It is idempotent — re-running is safe. It refuses to write to known
protected iOS paths (`/mnt/ios/private/var/tmp`, mobile `Library`,
`Documents`, `Media`).

Override the repo path with `POCKET_LAB_REPO=/path/to/repo` if you cloned
somewhere other than `/root/pocket-lab-v2-6`.

## What is *not* committed

The runtime `ios-write` symlink, the bridge contents, marker files, and
log output are local device state. They are excluded by `.gitignore` and
should never be committed. Same goes for the live UUID — it is not a
secret, but it is not portable, so treat it as device state, not a
constant.
