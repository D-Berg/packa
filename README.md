# Packa (WIP)

A simple package manager, see [packa-core](https://github.com/d-berg/packa-core) for manifests.

## Architechture

Each repositorie has a public key, minisign.pub, used to verify that the 
binary packages are valid.

The public repo key in each repo need to be signed by a maintainers key.
This verifies that the given repos manifests and public key can be trusted.

### Installation process
    1. verify <repo>/minisign.pub using the configured maintainer public key.
    2. load manifest and fetch binary and binary signature from configured mirrors.
    3. verify fetched binary using the fetched signature and repos public key.
    4. install binary package.

Each repo need to contain:
    - minisign.pub - key to verify binary packages
    - minisign.pub.minisign - signature of minisign.pub signed with maintainers private key


- binary packages hosted on binary repo signed with minisign
- binary repo, stupid http server, can be hosted by anything

## Lua configuration

Packa uses ordinary Lua tables for both persistent packages and project development shells. There is no configuration DSL.

Create `~/.config/packa/init.lua`:

```lua
return {
  version = 1,

  packages = {
    "git",
    "helix",
    "ripgrep",
  },

  install = {
    build_from_source = false,
  },
}
```

Apply it with:

```sh
packa apply
packa apply --config ./another-config.lua
```

### Development shells

Add a `packa.lua` to a project. Packa searches the current directory and its parents for this file.

```lua
return {
  version = 1,

  dev_shell = {
    packages = {
      "zig",
      "zls",
      "just",
    },

    environment = {
      ZIG_GLOBAL_CACHE_DIR = ".cache/zig",
    },
  },
}
```

Run `packa shell` to enter the environment. Development packages are added to the child shell's `PATH` without being linked globally.

The first run creates `packa.lock` beside `packa.lua`. Commit this data-only JSON file to reproduce the exact runtime package closure. If repository manifests later resolve the same configuration to different package IDs, Packa refuses to enter the shell. Review the change and run `packa shell --update` to refresh the lock.

Named shells use the `dev_shells` table:

```lua
return {
  version = 1,

  dev_shells = {
    default = {
      packages = { "zig", "zls" },
    },

    release = {
      packages = { "zig", "minisign", "zstd" },
      environment = { RELEASE = "1" },
    },
  },
}
```

Enter the named environment with `packa shell release`.

The configuration environment includes Lua's base, string, and table libraries. File loading and module loading are disabled. The returned value is validated against Packa's schema, and unknown fields are errors.
