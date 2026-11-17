# Retired 2026-11-17.
# oh-my-pi no longer uses this script. Upstream release tags merge into
# ompweb-dev/oh-my-pi branch oml (.github/workflows/omp-sync.yml). A push to
# oml builds and releases. New patches are ordinary commits on oml. Closing
# an upstream PR does not remove a patch; that takes an explicit revert on oml.
# The integration script still serves other projects. Do not point it at oh-my-pi.
echo "integration: oh-my-pi flow is retired; merge onto ompweb-dev/oh-my-pi branch oml" >&2
exit 1
