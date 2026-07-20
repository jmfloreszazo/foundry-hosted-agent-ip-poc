#!/usr/bin/env sh
set -eu
# sign-image.sh — sign the agent image right after the package step.
# The signature is what turns "an image in a registry" into "THIS image,
# built by MY pipeline, untampered". It is the link that ties the IP to its
# provenance (the subject of the Azure Artifact Signing article).
#
# Two paths; pick one based on your environment:
#   A) Azure Trusted Signing (managed identity, no keys to custody)
#   B) cosign keyless with OIDC (Sigstore) if you don't use Trusted Signing
#
# Expected variables: IMAGE_REF (acr.azurecr.io/agent@sha256:...)

: "${IMAGE_REF:?define IMAGE_REF with the image digest}"

echo "==> Signing ${IMAGE_REF}"

if [ "${SIGNING_MODE:-trusted}" = "trusted" ]; then
  # Path A: Azure Trusted Signing + notation
  notation sign \
    --plugin azure-kv \
    --id "${TRUSTED_SIGNING_CERT_PROFILE_ID}" \
    "${IMAGE_REF}"
else
  # Path B: cosign keyless (Sigstore, runner OIDC)
  COSIGN_EXPERIMENTAL=1 cosign sign --yes "${IMAGE_REF}"
fi

echo "==> Image signed. Provenance bound to the immutable digest."
