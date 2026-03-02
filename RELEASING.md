# Releasing

This repo publishes a Docker image and a Helm chart. The goal is that:

- CI publishes image tag = `Chart.yaml:version`
- Helm defaults to pulling image tag = `Chart.yaml:appVersion`
- We keep `version` and `appVersion` aligned so they match

## Release checklist

1. **Pick the next version**
   - Bump `version` and `appVersion` together in [Chart.yaml](Chart.yaml).
   - Example:
     - `version: 0.1.2`
     - `appVersion: "0.1.2"`

2. **Sanity-check Helm defaults**
   - Ensure [values.yaml](values.yaml) has `image.tag: ""` (empty), so the chart falls back to `.Chart.AppVersion`.
   - Ensure [templates/hook.yaml](templates/hook.yaml) renders the image like:
     - `{{ .Values.image.repository }}:{{ default .Chart.AppVersion .Values.image.tag }}`

3. **Run validations locally**
   - `helm lint .`
   - `helm template ci . --namespace default > /dev/null`
   - `./tests/run-bats.sh`
   - `./tests/run-e2e.sh`

4. **Update the changelog**
   - Add a new version entry to [CHANGELOG.md](CHANGELOG.md).

5. **Push to main**
   - CI on `main` will build+push the Docker image.
   - The Docker tag is derived from `Chart.yaml:version` in [.github/workflows/ci.yaml](.github/workflows/ci.yaml).

6. **Verify the published artifact**
   - Confirm the image exists:
     - `victorbecerra/ingress-migration-shell-operator:<version>`
   - Confirm Helm renders the expected tag by default:
     - `helm template . | grep -n "image:"`

## Notes

- If you ever need chart packaging/publishing (Helm repo, OCI chart push), add those steps here. Today CI only publishes the Docker image.
