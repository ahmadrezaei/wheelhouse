#!/bin/sh
# A fake exec credential plugin for tests. PLUGIN_MODE selects the behaviour; every other knob is an environment variable that the
# test puts into the kubeconfig stanza's `env`.
#
#   PLUGIN_COUNTER     file that holds how many times the plugin ran (the credential is tok-<n>)
#   PLUGIN_INFO_FILE   file that receives KUBERNETES_EXEC_INFO
#   PLUGIN_API_VERSION apiVersion to print (default client.authentication.k8s.io/v1)
#   PLUGIN_EXPIRY      expirationTimestamp (RFC 3339)
#   PLUGIN_SLEEP       seconds to sleep in mode "sleep"
[ -n "$PLUGIN_INFO_FILE" ] && printf '%s' "$KUBERNETES_EXEC_INFO" > "$PLUGIN_INFO_FILE"
n=1
if [ -n "$PLUGIN_COUNTER" ]; then
  [ -f "$PLUGIN_COUNTER" ] && n=$(( $(cat "$PLUGIN_COUNTER") + 1 ))
  printf '%s' "$n" > "$PLUGIN_COUNTER"
fi
ver="${PLUGIN_API_VERSION:-client.authentication.k8s.io/v1}"
exp=""
[ -n "$PLUGIN_EXPIRY" ] && exp=",\"expirationTimestamp\":\"$PLUGIN_EXPIRY\""
case "${PLUGIN_MODE:-token}" in
  token)
    printf '{"apiVersion":"%s","kind":"ExecCredential","status":{"token":"tok-%s"%s}}' "$ver" "$n" "$exp" ;;
  sleep)
    sleep "${PLUGIN_SLEEP:-1}"
    printf '{"apiVersion":"%s","kind":"ExecCredential","status":{"token":"tok-%s"%s}}' "$ver" "$n" "$exp" ;;
  cert)
    printf '{"apiVersion":"%s","kind":"ExecCredential","status":{"clientCertificateData":"CERT-%s","clientKeyData":"KEY-%s"%s}}' "$ver" "$n" "$n" "$exp" ;;
  malformed)
    echo 'this is not json' ;;
  empty)
    printf '{"apiVersion":"%s","kind":"ExecCredential","status":{}}' "$ver" ;;
  slow)
    sleep 30 ;;
  fail)
    echo "error: token=abcdef0123456789abcdef rejected by the identity provider" >&2
    echo "please run: aws sso login" >&2
    exit 3 ;;
  interactive)
    printf 'Enter the device code: ' >&2
    read code
    printf '{"apiVersion":"%s","kind":"ExecCredential","status":{"token":"tok-%s"%s}}' "$ver" "$code" "$exp" ;;
esac
