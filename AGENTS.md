# Development guidelines

This repository builds a Docker image of Oracle Hyperion Planning 11.2.26, with Essbase 21c and SQL Server, from installation media each user downloads from Oracle. `README.md` is the runbook: keep it in step with every change, including the table of Oracle defects when a workaround is added.

## Oracle's software stays out

- `media/` holds Oracle's downloads and `recordings/` holds raw configurator recordings. Git ignores both, apart from `media/*.sha256`, `media/.dockerignore` and `media/README.md`. Never commit anything else from them, and never commit `.env`.
- Never push an image built from this repository to a public registry: it contains Oracle software. The repository publishes scripts only.
- Don't copy text from Oracle's documentation or readmes into the repository. Part numbers and product names are fine.

## Building and testing

- A build from scratch takes about 1 hour 40 minutes under Rosetta: about 50 minutes for the 11.2.15 install and 45 for the 11.2.26 update. First start then configures for about 23 more. To test a change to the container scripts, build with `PATCHED_IMAGE`; for a change to the update, start from `INSTALLED_IMAGE`. "Building" in `README.md` shows both.
- Run `./build/check-media.sh` before building. A change to the media means changing the matching manifest and `media/.dockerignore` together; the script fails when they disagree.
- Shell scripts must pass `shellcheck`. `build/check-media.sh` also runs on the host, including macOS's bash 3.2, so it avoids bash 4 features such as `mapfile` and associative arrays. The other scripts only run inside the image.
- A configuration change is only proven on a fresh volume: `docker compose down -v`, then `docker compose up -d`, and wait for healthy. EPM fixes its host name and passwords at first start, so an existing volume can't show it.
- On Apple Silicon the image runs under Rosetta, and everything is slower. Automation that types into the configurator GUI with `xdotool` needs `--delay 150` or more, or characters get dropped.

## Response files

- `build/install-response.xml` is written from the installer's own product tree. `container/config-response.xml` and `container/webserver-response.xml` were recorded with the configurator and turned into templates whose placeholders `container/configure.sh` fills in.
- Change the configuration by recording again (`recorder/README.md` has the procedure), not by guessing at Oracle's schema.
