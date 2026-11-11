# Dev environment

The hello-web API and UI in namespace `hello-web-dev`, served at
`https://hello-web-dev.immutablesoftware.dev`. After setup, every push to `main`
builds `192.168.0.10:30500/hello-web-api:<commit sha>` (`build-api`) and
`192.168.0.10:30500/hello-web-ui:<commit sha>` (`build-ui`), then `deploy-dev`
in `.woodpecker.yml` renders those tags into copies of `api.yaml`, `ui.yaml`
and `ingress.yaml` and applies them, so env, spec and routing changes in those
three files reach dev on merge. It fails unless both rollouts finish, the
API's `/health` answers 200 and the UI's `/` answers 200.

CI applies those three files only. `namespace.yaml`, `rbac.yaml`,
`postgres.yaml`, `redis.yaml` and the sealed secrets are one-time admin
applies (below), and a change to any of them reaches the cluster only when an
admin applies it by hand.

| File | What |
|---|---|
| `namespace.yaml` | Namespace `hello-web-dev` |
| `rbac.yaml` | ServiceAccount `woodpecker/hello-web-deployer`, and a Role plus RoleBinding in `hello-web-dev` that let it read and create Deployments, Services and Ingresses, patch only `hello-web-api`, `hello-web-ui` and Ingress `hello-web`, and read ReplicaSets and Pods |
| `postgres.yaml` | Postgres 18 on a 5Gi PVC (storage class `fast`), so data survives restarts. ClusterIP |
| `redis.yaml` | Redis 8 with no persistence: a restart logs everyone out of dev. ClusterIP |
| `api.yaml` | The API Deployment and Service (port 80 to 8080). Non-root, read-only root filesystem, probes on `/health` |
| `ui.yaml` | The UI Deployment and Service (port 80 to 8080): nginx-unprivileged serving the static build, non-root (uid 101), read-only root filesystem with an in-memory `/tmp`, probes on `/` |
| `ingress.yaml` | Host `hello-web-dev.immutablesoftware.dev`: `/auth`, `/me` (Prefix), `/health` and `/openapi.json` (Exact) to the API, everything else to the UI. No `tls:` block, because TLS ends at Cloudflare |
| `dev-services-sealed.yaml` | Postgres and Redis passwords, sealed at setup (below) |
| `google-oauth-sealed.yaml` | Google OAuth client id and secret (`hello-web-google-oauth`) |

## One-time setup

Run from this directory with an admin kubeconfig. Steps 1 and 2 are never
applied by CI; step 3's app manifests are, on every push to `main`, after this
first apply.

1. Create the namespace and the deployer identity:

   ```sh
   kubectl apply -f namespace.yaml -f rbac.yaml
   ```

2. Generate the Postgres and Redis passwords and seal them. Hex, so the
   password needs no escaping inside the DSN in `api.yaml`. The plaintext only
   ever exists in the pipe:

   ```sh
   kubectl create secret generic dev-services -n hello-web-dev \
     --from-literal=postgres-password="$(openssl rand -hex 24)" \
     --from-literal=redis-password="$(openssl rand -hex 24)" \
     --dry-run=client -o yaml \
   | kubeseal --controller-namespace kube-system \
       --controller-name sealed-secrets-controller -o yaml \
   > dev-services-sealed.yaml
   kubectl apply -f dev-services-sealed.yaml
   kubectl get secret dev-services -n hello-web-dev   # the controller unsealed it
   ```

   Seal the Google OAuth Web client the same way. Create the client first
   (authorized origin `https://hello-web-dev.immutablesoftware.dev`, redirect URI
   `https://hello-web-dev.immutablesoftware.dev/auth/google/callback`); `read -rs` keeps the
   values out of shell history:

   ```sh
   read -rs GID; read -rs GSECRET
   kubectl create secret generic hello-web-google-oauth -n hello-web-dev \
     --from-literal=client-id="$GID" --from-literal=client-secret="$GSECRET" \
     --dry-run=client -o yaml \
   | kubeseal --controller-namespace kube-system \
       --controller-name sealed-secrets-controller -o yaml \
   > google-oauth-sealed.yaml
   unset GID GSECRET
   kubectl apply -f google-oauth-sealed.yaml
   kubectl get secret hello-web-google-oauth -n hello-web-dev
   ```

   Add a header comment to each sealed file recording the date and that the
   controller unsealed it, then commit them.

3. Start the data stores, then the app manifests rendered the way
   `deploy-dev` renders them, so the placeholder tag `set-by-pipeline` is
   never applied:

   ```sh
   kubectl apply -f postgres.yaml -f redis.yaml
   SHA=$(git rev-parse origin/main)
   OUT=$(mktemp -d)
   for f in api.yaml ui.yaml ingress.yaml; do
     sed "s#:set-by-pipeline#:$SHA#" "$f" > "$OUT/$f"
   done
   kubectl -n hello-web-dev apply -f "$OUT/api.yaml" -f "$OUT/ui.yaml" -f "$OUT/ingress.yaml"
   kubectl -n hello-web-dev rollout status deployment/hello-web-api --timeout=180s
   kubectl -n hello-web-dev rollout status deployment/hello-web-ui --timeout=180s
   ```

   Both images exist only if `build-api` and `build-ui` ran for that commit.
   Until a `main` build of the UI exists, skip `ui.yaml` and `ingress.yaml`
   and let the first merge apply them.

4. Check the deployer can do what `deploy-dev` does, and no more:

   ```sh
   AS=system:serviceaccount:woodpecker:hello-web-deployer
   kubectl auth can-i patch deployment/hello-web-api -n hello-web-dev --as=$AS   # yes
   kubectl auth can-i patch deployment/hello-web-ui -n hello-web-dev --as=$AS    # yes
   kubectl auth can-i patch ingress/hello-web -n hello-web-dev --as=$AS          # yes
   kubectl auth can-i watch deployments -n hello-web-dev --as=$AS                # yes
   kubectl auth can-i get secrets -n hello-web-dev --as=$AS                      # no
   kubectl auth can-i patch deployment/postgres -n hello-web-dev --as=$AS        # no
   kubectl auth can-i create rolebindings -n hello-web-dev --as=$AS              # no
   kubectl auth can-i delete deployments -n hello-web-dev --as=$AS               # no
   ```

5. Route the hostname through the Cloudflare tunnel (route, proxied DNS record
   and Access application, the same command role-up used; see
   `role-up/docs/deployment.md`, "External exposure"):

   ```sh
   python3 ~/.claude-test/skills/cloudflare-zero-trust/scripts/cf_ops.py \
     add-service "Hello Web Dev" hello-web-dev
   ```

   Never hand-roll the tunnel configuration `PUT`: it replaces every route.

6. Verify, first inside the LAN (straight to ingress-nginx) and then through
   Cloudflare:

   ```sh
   curl -sS -H 'Host: hello-web-dev.immutablesoftware.dev' http://192.168.0.10:30080/health
   # {"status":"ok"}
   curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' \
     -H 'Host: hello-web-dev.immutablesoftware.dev' http://192.168.0.10:30080/
   # 200 text/html
   ```

   Through Cloudflare the hostname sits behind Access, so check it in a
   signed-in browser.

## Re-applying a manifest

`api.yaml` and `ui.yaml` carry the placeholder tag, so a plain
`kubectl apply -f api.yaml` takes the API down. Re-apply them only through the
render in step 3, or let the next merge to `main` do it.

## What `serve` needs

`serve` connects to Redis (sign-in attempts and sessions) and to Postgres,
applying the goose migrations at startup before it builds the Casbin
enforcer. Either being down stops the pod starting, so `deploy-dev`'s
`/health` check fails rather than serving a half-working API. Google sign-in
reads `client-id` and `client-secret` from `hello-web-google-oauth`.

## The ServiceAccount tradeoff

On Woodpecker v3.14.1 any step in any repo on this server can set
`backend_options.kubernetes.serviceAccountName`, and nothing restricts the
name by repo or event (`pipeline/backend/kubernetes/pod.go` copies it into the
pod spec unconditionally). So a pull-request pipeline could deliberately run
as `hello-web-deployer`. What it would get is the Role above, in a dev
namespace: patch the two app Deployments, their Services and the Ingress, and
create any Deployment, Service or Ingress (`create` cannot be limited by
`resourceNames`). The widest of those is creating an Ingress, which could
claim paths on any hostname this ingress-nginx serves, not only
`hello-web-dev`. `kubectl apply` needs `create` only when an object is missing,
and step 3 creates all three, so dropping `create` from the Role after setup
would remove that reach at the cost of a new app object needing an admin
apply first. Patching the pod template does let such a
step run any image with the `dev-services` passwords in its environment, so
treat those as dev-only credentials. A kubeconfig in a push-only Woodpecker
secret would contain this better, at the cost of a long-lived credential; for
dev, the narrow SA was preferred.
