WIP

Odin library to watch for changes in a directory.

> [!NOTE]
> For personal use. I will look at issues/PRs at my leisure, or not at all.

## Platforms

- Linux (inotify)
- Windows (ReadDirectoryChangesExW)

## Usage

```odin
import "dirwatch"

watch, err := dirwatch.create(10)
defer dirwatch.destroy(&watch)

dirwatch.watch_dir(&watch, "./my-dir", recursive = true)

for {
	if data, ok := chan.try_recv(watch.chan); ok {
		log.info("Event received:", data)
	}
}
```

