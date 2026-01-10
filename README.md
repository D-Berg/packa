# Packa (WIP)

A simple package manager, see [packa-core](https://github.com/d-berg/packa-core) for manifests.

## Architechture

Each repositorie has a public key, minisign.pub, used to verify that the 
binary packages are valid.

The public repo key in each repo need to be signed by a maintainers key.
This verifies that the given repos manifests and public key can be trusted.

### Installation process
    1. verify <repo>/minisign.pub using maintainers public key specified in config.toml.
    2. load manifest and fetch binary and binary signature from mirrors specified in config.
    3. verify fetched binary using the fetched signature and repos public key.
    4. install binary package.

Each repo need to contain:
    - minisign.pub - key to verify binary packages
    - minisign.pub.minisign - signature of minisign.pub signed with maintainers private key


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
