# Post Mortem

A personal Android app for reviewing Lichess games with an AI coach. It pulls your games (or anyone's) from Lichess, runs Stockfish on the phone, and has Claude explain every move, plus a chatbox where Claude uses Stockfish and the Lichess API to answer questions.

## Getting the app

Every push to `main` is built on GitHub Actions. The newest APK is attached to the **latest** release: open the repo's Releases page on your phone, download `post-mortem.apk` and install it.

## Building

No local setup is needed. The workflow in `.github/workflows/build.yml` installs Flutter, fills in any missing platform files, builds a release APK for arm64 phones and publishes it.

`android/debug.keystore` is the app's signing key, kept in the repo so every build installs over the previous one. It only identifies this personal build.

## License

GPLv3, following the Lichess packages it builds on (`chessground`, `dartchess`).
