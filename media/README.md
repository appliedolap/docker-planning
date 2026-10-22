# Oracle media

Put the Oracle downloads here, as they are: one flat folder, with the file names Oracle gave them. The `*.sha256` manifests list the files the build needs, and "Getting the media" in the top-level README says what each one is and where to download it.

Check them before building:

```bash
./build/check-media.sh
```

Anything else here is ignored, and isn't even sent to Docker (see `.dockerignore`). None of the media is ever committed.
