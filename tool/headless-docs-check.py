#!/usr/bin/env python3
"""Keep the man page and shell completions in step with the CLI.

The flag table in native_engine/src/headless/cli.rs is the only place a flag
can be added; this script reads it and checks that

  * every flag appears in docs/netstudio-headless.1 and in both completions,
  * neither document mentions a long flag the binary does not accept,
  * the .TH version matches native_engine/Cargo.toml, and
  * no option block is documented twice (a copy-paste that renders fine but
    reads like two different flags).

Standard library only, and no build is needed: CI runs it before rendering.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(ROOT, 'native_engine', 'src', 'headless', 'cli.rs')
MAN = os.path.join(ROOT, 'docs', 'netstudio-headless.1')
BASH = os.path.join(ROOT, 'docs', 'completions', 'netstudio-headless.bash')
ZSH = os.path.join(ROOT, 'docs', 'completions', 'netstudio-headless.zsh')
CARGO = os.path.join(ROOT, 'native_engine', 'Cargo.toml')

# A long flag on the man page is written `\-\-probe\-interval`, but the
# second hyphen is often left plain (`\-\-pid-file`), so accept both.
MAN_LONG = re.compile(r'\\-\\-((?:[a-z0-9]+)(?:(?:\\-|-)[a-z0-9]+)*)')

problems = []


def fail(message):
    problems.append(message)


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def cli_flags(text):
    """Flags from the parse() arms, e.g. `"-c" | "--config" => {`."""
    long, short = set(), set()
    arm = re.compile(r'^\s*(?:"[^"]+"\s*\|\s*)*"[^"]+"\s*=>')
    for line in text.splitlines():
        if not arm.match(line):
            continue
        flags = re.findall(r'"([^"]*)"', line.split('=>', 1)[0])
        if not flags or not all(flag.startswith('-') for flag in flags):
            continue
        for flag in flags:
            (long if flag.startswith('--') else short).add(flag)
    return long, short


def man_flags(text):
    long = {'--' + match.replace('\\-', '-') for match in MAN_LONG.findall(text)}
    # Escaped hyphens inside long flags (`\-\-probe\-interval`) would read as
    # short flags (`-i`), so blank the long ones before looking for shorts.
    stripped = MAN_LONG.sub(' LONGOption ', text)
    short = {'-' + match for match in re.findall(r'\\-([A-Za-z])(?![A-Za-z0-9])', stripped)}
    return long, short


def present(text, flag):
    return re.search(r'(?<![\w-])' + re.escape(flag) + r'(?![\w-])', text) is not None


def compare_sets(label, expected, actual):
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if missing:
        fail('{} does not document {}'.format(label, ', '.join(missing)))
    if extra:
        fail('{} documents flags the CLI does not accept: {}'.format(
            label, ', '.join(extra)))
    return not missing and not extra


def compare_short(label, expected, text):
    missing = sorted(flag for flag in expected if not present(text, flag))
    if missing:
        fail('{} does not complete {}'.format(label, ', '.join(missing)))
    return not missing


def option_headers(text):
    """(line, header) for every .TP block that starts with a bold line."""
    lines = text.splitlines()
    headers = []
    for index, line in enumerate(lines):
        if line.strip() != '.TP' or index + 1 >= len(lines):
            continue
        header = lines[index + 1].strip()
        if header.startswith(('.B ', '.BR ', '.BI ')):
            headers.append((index + 2, ' '.join(header.split())))
    return headers


def check_duplicates(text):
    seen = {}
    for line, header in option_headers(text):
        if header in seen:
            fail('line {} repeats the option block from line {}: {}'.format(
                 line, seen[header], header))
        else:
            seen[header] = line


def check_version(man_text):
    cargo = re.search(r'^version = "([^"]+)"', read(CARGO), re.MULTILINE)
    if not cargo:
        fail('cannot read the version from native_engine/Cargo.toml')
        return
    # .TH NETSTUDIO-HEADLESS 1 "2026" "netstudio-headless 1.6.0" "User Commands"
    header = re.search(r'"netstudio-headless ([^"]+)"', man_text)
    if not header:
        fail('the .TH line does not carry "netstudio-headless <version>"')
    elif header.group(1) != cargo.group(1):
        fail('the man page says {}, Cargo.toml says {}'.format(
             header.group(1), cargo.group(1)))


def main():
    cli_long, cli_short = cli_flags(read(CLI))
    if not cli_long:
        fail('found no flags in {} (did the parser change shape?)'.format(CLI))
    man_text = read(MAN)
    man_long, man_short = man_flags(man_text)
    bash_text = read(BASH)
    zsh_text = read(ZSH)

    if compare_sets('man page (long)', cli_long, man_long):
        print('ok   man page: {} long flags'.format(len(cli_long)))
    if compare_sets('man page (short)', cli_short, man_short):
        print('ok   man page: {} short flags'.format(len(cli_short)))
    for label, text in (('bash completion', bash_text), ('zsh completion', zsh_text)):
        long_ok = compare_sets(label + ' (long)', cli_long, set(
            re.findall(r'(?<![\w-])--[a-z][a-z0-9-]*', text)
        ))
        short_ok = compare_short(label + ' (short)', cli_short, text)
        if long_ok and short_ok:
            print('ok   {}: {} long, {} short'.format(label, len(cli_long), len(cli_short)))

    before = len(problems)
    check_duplicates(man_text)
    if len(problems) == before:
        print('ok   man page: no duplicated option block')
    before = len(problems)
    check_version(man_text)
    if len(problems) == before:
        print('ok   man page: version matches Cargo.toml')

    if problems:
        for problem in problems:
            print('FAIL ' + problem)
        return 1
    print('{} flags; docs in step'.format(len(cli_long)))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())