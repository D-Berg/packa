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
