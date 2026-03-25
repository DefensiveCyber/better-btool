# better_btool.sh

A Splunk `btool` wrapper that adds stanza-level filtering, readable indented output, and colorized headers making it easier to quickly scan large btool outputs for what you actually care about.

## Features

- Filter stanzas by **enabled** or **disabled** state
- Filter stanzas by a **text pattern** (searches both the header and all key=value lines)
- **Indented body lines** for visual separation from stanza headers
- **Colorized stanza headers** (bold cyan by default, fully configurable)
- Save output to a file with `-o` while still printing to the terminal
- Verbose/debug mode with `-v`

## Requirements

- Bash 4.0+
- A working Splunk installation with `$SPLUNK_HOME/bin/splunk` accessible

## Installation

```bash
# Clone or download the script, then make it executable
chmod +x btool_filter.sh

# Optionally set your Splunk home if it differs from /opt/splunk
export SPLUNK_HOME=/opt/splunk
```

## Usage

```
btool_filter.sh [OPTIONS] -- <btool args>
```

Everything after `--` is passed directly to `btool`. For example, `-- inputs list --debug` runs `splunk btool inputs list --debug`.

## Flags

| Flag | Description |
|------|-------------|
| `-e` | Show only stanzas that are **enabled** (`disabled=false/0`, `enabled=true/1`, or no disabled key present) |
| `-d` | Show only stanzas that are **disabled** (`disabled=true/1`, `enabled=false/0`) |
| `-f <pattern>` | Show only stanzas containing `<pattern>` — case-insensitive substring match against the full stanza (header + all key=value lines) |
| `-c <color>` | Stanza header color (default: `bcyan`). See [Colors](#colors) below. Use `-c none` to disable. |
| `-C <path>` | Splunk home path (default: `$SPLUNK_HOME` or `/opt/splunk`) |
| `-b <path>` | Full path to the `splunk` binary directly (overrides `-C`) |
| `-o <file>` | Write output to `<file>` in addition to stdout |
| `-v` | Verbose — print debug info to stderr |
| `-h` | Show help |

If `-e` and `-d` are both given, stanzas matching either condition are shown.

## Examples

```bash
# All inputs stanzas (default bold cyan headers, indented body)
./btool_filter.sh -- inputs list

# Show only enabled inputs
./btool_filter.sh -e -- inputs list --debug

# Show only disabled transforms
./btool_filter.sh -d -- transforms list

# Show stanzas containing "syslog" anywhere in the stanza
./btool_filter.sh -f "syslog" -- props list --debug

# Combine: enabled stanzas that mention "monitor"
./btool_filter.sh -e -f "monitor" -- inputs list --debug

# Save results to a file (disable color to keep the file clean)
./btool_filter.sh -e -c none -o results.txt -- inputs list --debug

# Non-standard Splunk install path
./btool_filter.sh -C /opt/splunkforwarder -e -- inputs list --debug

# Point directly at the binary
./btool_filter.sh -b /usr/local/bin/splunk -d -- transforms list
```

## Output Format

Stanza headers stay flush left and are colorized. Key=value body lines are indented 3 spaces. Stanzas are separated by a blank line.

```
[monitor:///var/log/syslog]
   disabled = false
   index = main
   sourcetype = syslog

[monitor:///var/log/auth.log]
   disabled = false
   index = main
   sourcetype = linux_secure
```

## Colors

Stanza headers default to **bold cyan**. Override with `-c <color>`.

| Normal | Bold |
|--------|------|
| `red` | `bred` |
| `green` | `bgreen` |
| `yellow` | `byellow` |
| `blue` | `bblue` |
| `magenta` | `bmagenta` |
| `cyan` | `bcyan` ← default |
| `white` | `bwhite` |

Use `-c none` to disable color entirely recommended when using `-o` to write to a file, since ANSI escape codes will otherwise appear in the file as raw characters.

## Pattern Matching Note

The `-f` flag does a **case-insensitive substring match** against the entire stanza, including the header line and all key=value pairs. This means a pattern like `test` will match stanzas where `test` appears anywhere including as part of a longer word like `latest` or `attest`. To narrow results, use a more specific pattern:

```bash
# Too broad — matches "latest", "attest", etc.
./btool_filter.sh -f "test" -- inputs list

# More specific — matches stanzas with "test" as a path component
./btool_filter.sh -f "/test/" -- inputs list

# Match a specific key=value
./btool_filter.sh -f "index = test" -- inputs list
```

## License

MIT
