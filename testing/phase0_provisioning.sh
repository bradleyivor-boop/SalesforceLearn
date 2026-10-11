#!/usr/bin/env bash
# Phase 0 regression checks: org provisioning, CLI auth, core Revenue Cloud (RLM) object model present.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
export PATH="$HOME/.npm-global/bin:$PATH"
CURRENT_PHASE="Phase 0 - Org Provisioning"
echo "== ${CURRENT_PHASE} =="

ORG_JSON=$(sf org display --json 2>/dev/null)
STATUS=$(echo "$ORG_JSON" | jq -r '.result.connectedStatus')
assert_eq "TC-0.1 Default org is connected" "Connected" "$STATUS"

ORG_ID=$(echo "$ORG_JSON" | jq -r '.result.id')
assert_not_empty "TC-0.2 Org Id is present" "$ORG_ID"

ALL_OBJECTS=$(sf sobject list --sobject all --json 2>/dev/null | jq -r '.result[]')
RLM_OBJECTS=(ProductCatalog ProductCategory Product2 Pricebook2 PricebookEntry Quote QuoteLineItem ProductAttributeDefinition ProductComponentGroup ProductRelatedComponent LegalEntity)
for OBJ in "${RLM_OBJECTS[@]}"; do
  assert_contains "TC-0.3 ${OBJ} object available in org" "$ALL_OBJECTS" "$OBJ"
done

print_summary
exit $?
