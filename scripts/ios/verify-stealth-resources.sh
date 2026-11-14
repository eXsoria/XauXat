#!/usr/bin/env bash
set -euo pipefail
app=${1:?Pass the built app path}
test -d "$app/XauXatLLVC.mlmodelc"
test -s "$app/LLVC-LICENSE.txt"
echo "Verified bundled Stealth Core ML model and license."
