#compdef netstudio-headless
# Install: sudo cp this file /usr/local/share/zsh/site-functions/_netstudio-headless

_arguments -s \
  '(-c --config)'{-c,--config}'[Target configuration file]:file:_files' \
  '--check[Validate config, paths and listen address, then exit]' \
  '--once[Probe every target once, print a snapshot, exit]' \
  '--interval[Snapshot interval in seconds]:seconds:' \
  '--probe-interval[Probe cadence override in seconds]:seconds:' \
  '--probe-concurrency[Maximum probes in flight]:count:' \
  '--watch-config[Reload the config file when it changes]:seconds:' \
  '--listen[Serve HTTP on ADDR]:address:' \
  '--output[Write the latest snapshot to PATH]:file:_files' \
  '--pid-file[Claim PATH and write the pid]:file:_files' \
  '--http-token-file[Bearer token file]:file:_files' \
  '(-q --quiet)'{-q,--quiet}'[Do not stream snapshots to stdout]' \
  '--format[Output format]:mode:(auto json text)' \
  '--color[Colour mode]:when:(auto always never)' \
  '--no-color[Same as --color never]' \
  '--log-level[Log verbosity]:level:(error warn info debug)' \
  '--log-format[Log line format]:format:(text json)' \
  '(-h --help)'{-h,--help}'[Print help and exit]' \
  '(-V --version)'{-V,--version}'[Print the version and exit]'