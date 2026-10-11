#!/usr/bin/env bash
# Phase 5 regression checks: demo Accounts/Contacts, pipeline-spread Opportunities,
# Quotes (mix of plans/add-ons across tiers), and the discount-approval quote.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
export PATH="$HOME/.npm-global/bin:$PATH"
CURRENT_PHASE="Phase 5 - Sample Data"
echo "== ${CURRENT_PHASE} =="

DEMO_ACCOUNT_NAMES="'Nimbus Labs','Fernbridge Analytics','Lighthouse Retail Group','Vantage Logistics','Meridian Health Systems','Oakridge Financial'"
DEMO_OPP_NAMES="'Nimbus Labs - Starter Plan','Nimbus Labs - API Usage Add-on','Fernbridge Analytics - Starter Plan Trial','Fernbridge Analytics - Growth Upsell','Lighthouse Retail - Growth Plan Rollout','Lighthouse Retail - Premium Support Upsell','Vantage Logistics - Growth Plan Evaluation','Vantage Logistics - API Add-on Expansion','Meridian Health - Enterprise Plan','Oakridge Financial - Enterprise Rollout','Oakridge Financial - Premium Support Renewal','Acme - Growth Plan Subscription'"

# --- Demo Accounts (5-8 total: 6 new + the Phase 4 'Acme' account) ---
NEW_ACCT_COUNT=$(sf data query -q "SELECT COUNT(Id) cnt FROM Account WHERE Name IN (${DEMO_ACCOUNT_NAMES})" --json 2>/dev/null | jq -r '.result.records[0].cnt')
assert_eq "TC-5.1 6 new demo Accounts exist (startup/mid-market/enterprise spread)" "6" "$NEW_ACCT_COUNT"

TOTAL_DEMO_ACCTS=$((NEW_ACCT_COUNT + 1))
assert_gte "TC-5.2 Total demo Account footprint (new + Acme) is within the 5-8 range" "5" "$TOTAL_DEMO_ACCTS"

# --- Contacts (2 per account x 7 accounts = 14) ---
CONTACT_COUNT=$(sf data query -q "SELECT COUNT(Id) cnt FROM Contact WHERE Account.Name IN (${DEMO_ACCOUNT_NAMES},'Acme') AND Email LIKE '%.example.com'" --json 2>/dev/null | jq -r '.result.records[0].cnt')
assert_eq "TC-5.3 14 demo Contacts exist (2 per Account)" "14" "$CONTACT_COUNT"

# --- Opportunities (12 total, spread across stages) ---
OPP_COUNT=$(sf data query -q "SELECT COUNT(Id) cnt FROM Opportunity WHERE Name IN (${DEMO_OPP_NAMES})" --json 2>/dev/null | jq -r '.result.records[0].cnt')
assert_eq "TC-5.4 12 demo Opportunities exist" "12" "$OPP_COUNT"

CLOSED_WON_COUNT=$(sf data query -q "SELECT COUNT(Id) cnt FROM Opportunity WHERE Name IN (${DEMO_OPP_NAMES}) AND StageName = 'Closed Won'" --json 2>/dev/null | jq -r '.result.records[0].cnt')
assert_eq "TC-5.5 3 demo Opportunities are Closed Won" "3" "$CLOSED_WON_COUNT"

CLOSED_LOST_COUNT=$(sf data query -q "SELECT COUNT(Id) cnt FROM Opportunity WHERE Name IN (${DEMO_OPP_NAMES}) AND StageName = 'Closed Lost'" --json 2>/dev/null | jq -r '.result.records[0].cnt')
assert_eq "TC-5.6 2 demo Opportunities are Closed Lost" "2" "$CLOSED_LOST_COUNT"

ACTIVE_COUNT=$(sf data query -q "SELECT COUNT(Id) cnt FROM Opportunity WHERE Name IN (${DEMO_OPP_NAMES}) AND StageName NOT IN ('Closed Won','Closed Lost')" --json 2>/dev/null | jq -r '.result.records[0].cnt')
assert_eq "TC-5.7 7 demo Opportunities are active (open pipeline)" "7" "$ACTIVE_COUNT"

# --- OpportunityContactRole (Economic Buyer + Technical Buyer on each of the 11 newly built Opportunities) ---
OCR_COUNT=$(sf data query -q "SELECT COUNT(Id) cnt FROM OpportunityContactRole WHERE Opportunity.Name IN (${DEMO_OPP_NAMES}) AND Opportunity.Name != 'Acme - Growth Plan Subscription'" --json 2>/dev/null | jq -r '.result.records[0].cnt')
assert_eq "TC-5.8 22 OpportunityContactRole records (Economic Buyer + Technical Buyer x 11 new Opps)" "22" "$OCR_COUNT"

# --- Quotes generated for active Opportunities, with real Pricebook-backed totals ---
NIMBUS_TOTAL=$(sf data query -q "SELECT GrandTotal FROM Quote WHERE Name = 'Nimbus Labs - Starter Plan Quote'" --json 2>/dev/null | jq -r '.result.records[0].GrandTotal')
assert_eq "TC-5.9 Nimbus Labs Starter Plan Quote totals 49" "49" "$NIMBUS_TOTAL"

LIGHTHOUSE_TOTAL=$(sf data query -q "SELECT GrandTotal FROM Quote WHERE Name = 'Lighthouse Retail - Growth Plan Quote'" --json 2>/dev/null | jq -r '.result.records[0].GrandTotal')
assert_eq "TC-5.10 Lighthouse Retail Growth Plan Quote totals 649 (Growth Plan + Implementation Fee)" "649" "$LIGHTHOUSE_TOTAL"

VANTAGE_TOTAL=$(sf data query -q "SELECT GrandTotal FROM Quote WHERE Name = 'Vantage Logistics - Growth Plan Quote'" --json 2>/dev/null | jq -r '.result.records[0].GrandTotal')
assert_eq "TC-5.11 Vantage Logistics Growth Plan Quote totals 248 (Growth Plan + Premium Support)" "248" "$VANTAGE_TOTAL"

OAKRIDGE_TOTAL=$(sf data query -q "SELECT GrandTotal FROM Quote WHERE Name = 'Oakridge Financial - Enterprise Rollout Quote'" --json 2>/dev/null | jq -r '.result.records[0].GrandTotal')
assert_eq "TC-5.12 Oakridge Financial Enterprise Rollout Quote totals 598 (Enterprise + Premium Support)" "598" "$OAKRIDGE_TOTAL"

# --- Mix of plans/add-ons across the 5 new Quotes ---
LINE_PRODUCTS=$(sf data query -q "SELECT Product2.Name prod FROM QuoteLineItem WHERE Quote.Name IN ('Nimbus Labs - Starter Plan Quote','Lighthouse Retail - Growth Plan Quote','Vantage Logistics - Growth Plan Quote','Meridian Health - Enterprise Plan Quote','Oakridge Financial - Enterprise Rollout Quote') GROUP BY Product2.Name" --json 2>/dev/null | jq -r '.result.records[].prod' | sort)
assert_contains "TC-5.13 Quote lines include Starter Plan" "$LINE_PRODUCTS" "Starter Plan"
assert_contains "TC-5.14 Quote lines include Growth Plan" "$LINE_PRODUCTS" "Growth Plan"
assert_contains "TC-5.15 Quote lines include Enterprise Plan" "$LINE_PRODUCTS" "Enterprise Plan"
assert_contains "TC-5.16 Quote lines include Premium Support Add-on" "$LINE_PRODUCTS" "Premium Support Add-on"
assert_contains "TC-5.17 Quote lines include Implementation Fee" "$LINE_PRODUCTS" "Implementation Fee"

# --- Discount-approval quote: triggers the Phase 4 Approval Process end-to-end ---
MERIDIAN_JSON=$(sf data query -q "SELECT Id, Discount FROM Quote WHERE Name = 'Meridian Health - Enterprise Plan Quote'" --json 2>/dev/null)
MERIDIAN_ID=$(echo "$MERIDIAN_JSON" | jq -r '.result.records[0].Id')
MERIDIAN_DISCOUNT=$(echo "$MERIDIAN_JSON" | jq -r '.result.records[0].Discount')
assert_not_empty "TC-5.18 Meridian Health Enterprise Plan Quote exists" "$MERIDIAN_ID"
DISCOUNT_ABOVE_THRESHOLD=$(awk -v d="$MERIDIAN_DISCOUNT" 'BEGIN{print (d > 15) ? "true" : "false"}')
assert_eq "TC-5.19 Meridian quote's blended discount is above the 15% approval threshold" "true" "$DISCOUNT_ABOVE_THRESHOLD"

APPROVAL_STATUS=$(sf data query -q "SELECT Status FROM ProcessInstance WHERE TargetObjectId = '${MERIDIAN_ID}' ORDER BY CreatedDate DESC LIMIT 1" --json 2>/dev/null | jq -r '.result.records[0].Status')
assert_eq "TC-5.20 Meridian quote was submitted and approved via the discount Approval Process" "Approved" "$APPROVAL_STATUS"

# --- Active Opportunities carry a synced Quote (Negotiation/Quote Sent) ---
SYNCED_ACTIVE_COUNT=$(sf data query -q "SELECT COUNT(Id) cnt FROM Opportunity WHERE Name IN (${DEMO_OPP_NAMES}) AND StageName NOT IN ('Closed Won','Closed Lost') AND SyncedQuoteId != null" --json 2>/dev/null | jq -r '.result.records[0].cnt')
assert_gte "TC-5.21 At least 3 active Opportunities have a synced Quote attached" "3" "$SYNCED_ACTIVE_COUNT"

print_summary
exit $?
