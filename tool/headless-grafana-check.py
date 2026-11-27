#!/usr/bin/env python3
"""Check the Grafana dashboard against the metrics the daemon exposes.

Grafana renders any expression, so a renamed metric or a typo in a legend
shows up as an empty panel that nobody notices. This reads metrics.rs (the
only place a metric name or label is defined) and the dashboard, and fails on

  * an expression that names a netstudio_* metric metrics.rs does not emit,
  * a legend that references a label the series does not carry,
  * duplicate panel ids or a panel outside the 24-column grid,
  * a panel that does not point at the dashboard datasource, or a missing
    datasource template and uid.

Standard library only; CI runs it next to the man page check.
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
METRICS = os.path.join(ROOT, 'native_engine', 'src', 'headless', 'metrics.rs')
DASHBOARD = os.path.join(ROOT, 'deploy', 'grafana', 'netstudio-headless.json')

problems = []


def fail(message):
    problems.append(message)


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def main():
    source = read(METRICS).split('#[cfg(test)]')[0]
    # Names appear both as a family argument ("netstudio_target_rtt_avg_ms")
    # and as a literal emission ("netstudio_ready {}"), so scan every
    # occurrence in the non-test part of the file.
    metrics = set(re.findall(r'\bnetstudio_[a-z0-9_]+', source))
    # Every label name in the file, from both the `labels()` helper and the
    # per-family ones (`kind=`, `path=`, `result=`).
    labels = set(re.findall(r'([a-z_]+)=\\"', source))
    if not metrics or 'id' not in labels:
        fail('could not read the metric and label names from {}'.format(METRICS))

    try:
        dashboard = json.loads(read(DASHBOARD))
    except ValueError as error:
        fail('{} is not valid JSON: {}'.format(DASHBOARD, error))
        report()
        return 1

    for key in ('uid', 'title', 'panels'):
        if not dashboard.get(key):
            fail('the dashboard has no {}'.format(key))

    variables = [item.get('name') for item in dashboard.get('templating', {}).get('list', [])]
    if 'datasource' not in variables:
        fail('there is no datasource template variable')
    expected = {'type': 'prometheus', 'uid': '${datasource}'}

    seen = set()
    panels = dashboard.get('panels', [])
    for panel in panels:
        panel_id = panel.get('id')
        if panel_id in seen:
            fail('duplicate panel id {}'.format(panel_id))
        seen.add(panel_id)
        if panel.get('type') == 'row':
            continue
        position = panel.get('gridPos', {})
        if position.get('x', 0) < 0 or position.get('x', 0) + position.get('w', 0) > 24:
            fail('panel {} ({}) is outside the 24-column grid'.format(panel_id, panel.get('title')))
        if not position.get('h'):
            fail('panel {} ({}) has no height'.format(panel_id, panel.get('title')))
        if panel.get('datasource') != expected:
            fail('panel {} ({}) does not use the datasource variable'.format(panel_id, panel.get('title')))
        targets = panel.get('targets') or []
        if not targets:
            fail('panel {} ({}) has no query'.format(panel_id, panel.get('title')))
        for target in targets:
            expression = target.get('expr') or ''
            for name in re.findall(r'\bnetstudio_[a-z0-9_]+', expression):
                if name not in metrics:
                    fail('panel {} ({}) queries {}, which the daemon does not emit'.format(
                         panel_id, panel.get('title'), name))
            legend = target.get('legendFormat') or ''
            for label in re.findall(r'\{\{\s*([a-z_]+)\s*\}\}', legend):
                if label not in labels:
                    fail('panel {} ({}) legends {{{{{}}}}}, which is not a label'.format(
                         panel_id, panel.get('title'), label))

    if not problems:
        print('ok   {} panels, {} queries, {} metrics, {} labels'.format(
              len([panel for panel in panels if panel.get('type') != 'row']),
              sum(len(panel.get('targets') or []) for panel in panels),
              len(metrics), len(labels)))
    report()
    return 1 if problems else 0


def report():
    for problem in problems:
        print('FAIL ' + problem)


if __name__ == '__main__':
    raise SystemExit(main())