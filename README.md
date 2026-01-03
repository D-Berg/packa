# Packa (WIP)

A simple package manager

## Architechture
- binary packages hosted on binary repo signed with minisign
- binary repo, stupid http server, can be hosted by anything

## TODO

- [ ] config file ~/.config/packa/packa.ini (or zon for ease) to support multible repos
    - [ ] speficy public key of repo
    - [ ] add cli support for installing from other repo than core
- [ ] fix installing
    - [ ] dependency resolving, (do I need to make a build graph??)
- [ ] cli info command
- [ ] look into sandboxing build (mac, linux, freebsd?)
- [ ] setup github ci
- [ ] support creating build archive and sign it with build cli flags
    - `--archive/-a`
    - `--sign/-s`, will use private key in ~/minisign (Note to self: DONT LEAK)
- [ ] launch stupid server on my domain
