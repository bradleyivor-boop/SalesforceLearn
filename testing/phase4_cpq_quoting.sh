#!/usr/bin/env bash
# Phase 4 regression checks: Opportunity/Quote build, Quote Line Items, discount-based
# Approval Process (positive + negative case), and native Quote <-> Opportunity sync.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
export PATH="$HOME/.npm-global/bin:$PATH"
CURRENT_PHASE="Phase 4 - CPQ / Quoting"
echo "== ${CURRENT_PHASE} =="

# --- Opportunity ---
OPP_JSON=$(sf data query -q "SELECT Id, RecordType.DeveloperName, Pricebook2.Name, StageName, SyncedQuoteId, Amount FROM Opportunity WHERE Name = 'Acme - Growth Plan Subscription'" --json 2>/dev/null)
OPP_ID=$(echo "$OPP_JSON" | jq -r '.result.records[0].Id')
assert_not_empty "TC-4.1 Opportunity 'Acme - Growth Plan Subscription' exists" "$OPP_ID"

OPP_RT=$(echo "$OPP_JSON" | jq -r '.result.records[0].RecordType.DeveloperName')
assert_eq "TC-4.2 Opportunity uses New_Business record type" "New_Business" "$OPP_RT"

# --- Quote (primary, blended-discount quote) ---
QUOTE_JSON=$(sf data query -q "SELECT Id, OpportunityId, Pricebook2.Name, Discount, GrandTotal FROM Quote WHERE Name = 'Acme Growth Plan Quote'" --json 2>/dev/null)
QUOTE_ID=$(echo "$QUOTE_JSON" | jq -r '.result.records[0].Id')
assert_not_empty "TC-4.3 Quote 'Acme Growth Plan Quote' exists" "$QUOTE_ID"

QUOTE_OPP_LINK=$(echo "$QUOTE_JSON" | jq -r '.result.records[0].OpportunityId')
assert_eq "TC-4.4 Quote is linked to the Opportunity" "$OPP_ID" "$QUOTE_OPP_LINK"

QUOTE_PB=$(echo "$QUOTE_JSON" | jq -r '.result.records[0].Pricebook2.Name')
assert_eq "TC-4.5 Quote uses Standard Price Book" "Standard Price Book" "$QUOTE_PB"

# --- Quote Line Items ---
QLI_JSON=$(sf data query -q "SELECT Product2.Name, Quantity, UnitPrice, Discount, TotalPrice, SellingModelType FROM QuoteLineItem WHERE QuoteId = '${QUOTE_ID}' ORDER BY Product2.Name" --json 2>/dev/null)
QLI_COUNT=$(echo "$QLI_JSON" | jq -r '.result.totalSize')
assert_eq "TC-4.6 Quote has 3 line items (Growth Plan, Premium Support, Implementation Fee)" "3" "$QLI_COUNT"

GROWTH_DISCOUNT=$(echo "$QLI_JSON" | jq -r '.result.records[] | select(.Product2.Name=="Growth Plan") | .Discount')
assert_eq "TC-4.7 Growth Plan line has a 20% discount" "20" "$GROWTH_DISCOUNT"

QUOTE_BLENDED_DISCOUNT=$(echo "$QUOTE_JSON" | jq -r '.result.records[0].Discount')
assert_eq "TC-4.8 Quote's blended discount is below the 15% approval threshold" "3.98395722" "$QUOTE_BLENDED_DISCOUNT"

# --- High-discount Quote (approval positive case) ---
HIGH_Q_JSON=$(sf data query -q "SELECT Id, Discount FROM Quote WHERE Name = 'Acme Growth Plan Quote - High Discount'" --json 2>/dev/null)
HIGH_Q_ID=$(echo "$HIGH_Q_JSON" | jq -r '.result.records[0].Id')
assert_not_empty "TC-4.9 High-discount test Quote exists" "$HIGH_Q_ID"

HIGH_Q_DISCOUNT=$(echo "$HIGH_Q_JSON" | jq -r '.result.records[0].Discount')
assert_eq "TC-4.10 High-discount Quote's discount is 25% (above threshold)" "25" "$HIGH_Q_DISCOUNT"

# --- Approval Process: positive case already submitted+approved in this org ---
APPROVAL_STATUS=$(sf data query -q "SELECT Status FROM ProcessInstance WHERE TargetObjectId = '${HIGH_Q_ID}' ORDER BY CreatedDate DESC LIMIT 1" --json 2>/dev/null | jq -r '.result.records[0].Status')
assert_eq "TC-4.11 High-discount Quote was approved via the Approval Process" "Approved" "$APPROVAL_STATUS"

# --- Approval Process: negative case (blended discount under threshold must be rejected at submit time) ---
TMP_APEX=$(mktemp /tmp/phase4_negative_approval_XXXX.apex)
cat > "$TMP_APEX" <<EOF
Boolean rejected = false;
try {
    Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
    req.setObjectId('${QUOTE_ID}');
    req.setSubmitterId(UserInfo.getUserId());
    Approval.process(req);
} catch (Exception e) {
    rejected = e.getMessage().contains('NO_APPLICABLE_PROCESS');
}
System.debug('PHASE4_NEG_APPROVAL_REJECTED:' + rejected);
EOF
NEG_APPROVAL_OUTPUT=$(sf apex run --file "$TMP_APEX" 2>/dev/null)
rm -f "$TMP_APEX"
# Scope to the USER_DEBUG log line only - the echoed Apex source (also printed by `sf apex run`)
# contains the same literal string and would otherwise be matched first, capturing an empty value.
NEG_APPROVAL_RESULT=$(echo "$NEG_APPROVAL_OUTPUT" | grep 'USER_DEBUG' | grep -o 'PHASE4_NEG_APPROVAL_REJECTED:[a-z]*' | head -1 | cut -d: -f2)
assert_eq "TC-4.12 Low-discount Quote cannot enter the High Discount approval process" "true" "$NEG_APPROVAL_RESULT"

# --- Native Quote -> Opportunity sync (no custom code) ---
OPP_SYNC_JSON=$(sf data query -q "SELECT SyncedQuoteId, Amount, StageName FROM Opportunity WHERE Id = '${OPP_ID}'" --json 2>/dev/null)
SYNCED_QUOTE_ID=$(echo "$OPP_SYNC_JSON" | jq -r '.result.records[0].SyncedQuoteId')
assert_eq "TC-4.13 Opportunity.SyncedQuoteId points at the synced Quote" "$QUOTE_ID" "$SYNCED_QUOTE_ID"

OPP_AMOUNT=$(echo "$OPP_SYNC_JSON" | jq -r '.result.records[0].Amount')
QUOTE_GRAND_TOTAL=$(echo "$QUOTE_JSON" | jq -r '.result.records[0].GrandTotal')
assert_eq "TC-4.14 Opportunity.Amount matches the synced Quote's Grand Total" "$QUOTE_GRAND_TOTAL" "$OPP_AMOUNT"

OLI_COUNT=$(sf data query -q "SELECT COUNT(Id) cnt FROM OpportunityLineItem WHERE OpportunityId = '${OPP_ID}'" --json 2>/dev/null | jq -r '.result.records[0].cnt')
assert_eq "TC-4.15 Opportunity has 3 synced line items" "3" "$OLI_COUNT"

OPP_STAGE=$(echo "$OPP_SYNC_JSON" | jq -r '.result.records[0].StageName')
assert_eq "TC-4.16 Opportunity advanced to 'Quote Sent' (Phase 2's validation rule allows it once synced)" "Quote Sent" "$OPP_STAGE"

print_summary
exit $?
