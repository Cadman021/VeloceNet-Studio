# Kubernetes manifests

The daemon is a single container with one ConfigMap and no storage: it keeps
the latest snapshot in an `emptyDir`, and everything else is derived from the
probes it runs.

```bash
docker build -f native_engine/Dockerfile -t netstudio-headless:1.6.0 .
kubectl apply -f deploy/kubernetes/configmap.yaml
kubectl apply -f deploy/kubernetes/deployment.yaml
kubectl apply -f deploy/kubernetes/service.yaml
kubectl port-forward svc/netstudio-headless 9101:9101
curl -s http://127.0.0.1:9101/api/v1/status | head
```

Edit `configmap.yaml` (or export a file from the desktop app) and
`kubectl apply` it again: `--watch-config 60` notices the mounted file change
within a minute, without a restart and without losing the probe history.

## Probes

* `livenessProbe` uses `/healthz`, which answers while the loop runs. A
  network outage must not restart the pod, so the network state is not part
  of liveness.
* `readinessProbe` uses `/readyz`, which stays `503` until every target has a
  sample. A pod that cannot reach its targets is kept out of the Service
  instead of reporting fabricated zeros.
* With `--http-token-file`, `/readyz` requires a token and kubelet cannot
  send one. Use an `exec` probe instead, which runs the binary's own client:

  ```yaml
  readinessProbe:
    exec:
      command:
        - /usr/local/bin/netstudio-headless
        - --health-check
        - http://127.0.0.1:9101/readyz
    periodSeconds: 10
  ```

  with the token available as `NETSTUDIO_HTTP_TOKEN` (from a Secret) and
  `/readyz` protected on the server side by the same value.

## ICMP

ICMP probes need a raw socket (`NET_RAW`); TCP, HTTP and HTTPS work without
it. `deployment.yaml` drops all capabilities and adds `NET_RAW` back so the
requirement is explicit; remove it when the config has no ICMP targets. Some
clusters block raw sockets by policy, in which case ICMP targets report a
permission error while the rest keep working.

## Scaling

Keep `replicas: 1` per config. Each instance probes on its own, so extra
replicas duplicate the probe traffic and split the Service across pods that
have no shared state. To monitor from several vantage points, give each
deployment its own config and a distinct `--listen` port label.
