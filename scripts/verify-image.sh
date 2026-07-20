#!/usr/bin/env sh
set -eu
# verify-image.sh — verify signature BEFORE deploying.
# If the image is not signed by your identity / chain of trust, the deploy
# is aborted. This prevents deploying a tampered or unknown-origin image
# even if someone managed to push something to the registry.

: "${IMAGE_REF:?define IMAGE_REF with the image digest}"

echo "==> Verifying signature of ${IMAGE_REF}"

if [ "${SIGNING_MODE:-trusted}" = "trusted" ]; then
  notation verify "${IMAGE_REF}"
else
  COSIGN_EXPERIMENTAL=1 cosign verify \
    --certificate-identity-regexp "${EXPECTED_IDENTITY_REGEX}" \
    --certificate-oidc-issuer-regexp "${EXPECTED_ISSUER_REGEX}" \
    "${IMAGE_REF}"
fi

echo "==> Signature valid. Provenance confirmed. Continuing with deploy."
