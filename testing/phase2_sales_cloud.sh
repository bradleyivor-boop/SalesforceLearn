#!/usr/bin/env bash
# Phase 2 regression checks: Lead fields/assignment/conversion mapping, Account/Opportunity
# record types, custom sales process & stages, Path, contact roles, validation rule,
# and that Collaborative Forecasting is active.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
export PATH="$HOME/.npm-global/bin:$PATH"
CURRENT_PHASE="Phase 2 - Sales Cloud Configuration"
echo "== ${CURRENT_PHASE} =="

# --- Lead / Opportunity custom field: Target_Plan_Tier__c ---
LEAD_VALUES=$(sf sobject describe --sobject Lead --json 2>/dev/null | jq -r '.result.fields[] | select(.name=="Target_Plan_Tier__c") | .picklistValues[].value')
for V in Starter Growth Enterprise; do
  assert_contains "TC-2.1 Lead.Target_Plan_Tier__c includes '${V}'" "$LEAD_VALUES" "$V"
done

OPP_VALUES=$(sf sobject describe --sobject Opportunity --json 2>/dev/null | jq -r '.result.fields[] | select(.name=="Target_Plan_Tier__c") | .picklistValues[].value')
for V in Starter Growth Enterprise; do
  assert_contains "TC-2.2 Opportunity.Target_Plan_Tier__c includes '${V}'" "$OPP_VALUES" "$V"
done

# --- Field-level security on Admin profile (this org does NOT auto-grant FLS to the
# profile for newly-created custom fields -- it auto-creates orphaned permission sets
# instead, which leaves the field invisible via describe/UI until granted explicitly) ---
LEAD_FLS=$(sf data query -q "SELECT PermissionsRead, PermissionsEdit FROM FieldPermissions WHERE Field = 'Lead.Target_Plan_Tier__c' AND Parent.Profile.Name = 'System Administrator'" --json 2>/dev/null | jq -r '.result.records[0].PermissionsEdit')
assert_eq "TC-2.1b Admin profile has edit FLS on Lead.Target_Plan_Tier__c" "true" "$LEAD_FLS"

OPP_FLS=$(sf data query -q "SELECT PermissionsRead, PermissionsEdit FROM FieldPermissions WHERE Field = 'Opportunity.Target_Plan_Tier__c' AND Parent.Profile.Name = 'System Administrator'" --json 2>/dev/null | jq -r '.result.records[0].PermissionsEdit')
assert_eq "TC-2.2b Admin profile has edit FLS on Opportunity.Target_Plan_Tier__c" "true" "$OPP_FLS"

# --- Lead reuses standard fields instead of redundant custom ones ---
LEAD_SOURCE_TYPE=$(sf sobject describe --sobject Lead --json 2>/dev/null | jq -r '.result.fields[] | select(.name=="LeadSource") | .type')
assert_eq "TC-2.3 Lead.LeadSource (standard) used for Lead Source" "picklist" "$LEAD_SOURCE_TYPE"

LEAD_EMP_TYPE=$(sf sobject describe --sobject Lead --json 2>/dev/null | jq -r '.result.fields[] | select(.name=="NumberOfEmployees") | .type')
assert_eq "TC-2.4 Lead.NumberOfEmployees (standard) used for Company Size" "int" "$LEAD_EMP_TYPE"

# --- Lead Assignment Rule ---
AR_JSON=$(sf data query -q "SELECT Name, SobjectType, Active FROM AssignmentRule WHERE SobjectType = 'Lead'" --json 2>/dev/null)
AR_ACTIVE=$(echo "$AR_JSON" | jq -r '.result.records[0].Active')
assert_eq "TC-2.5 Lead assignment rule exists and is active" "true" "$AR_ACTIVE"

# --- Record Types ---
RT_JSON=$(sf data query -q "SELECT SobjectType, DeveloperName, IsActive, BusinessProcessId FROM RecordType WHERE DeveloperName IN ('Customer','New_Business')" --json 2>/dev/null)

ACCT_RT_ACTIVE=$(echo "$RT_JSON" | jq -r '.result.records[] | select(.SobjectType=="Account") | .IsActive')
assert_eq "TC-2.6 Account.Customer record type is active" "true" "$ACCT_RT_ACTIVE"

OPP_RT_ACTIVE=$(echo "$RT_JSON" | jq -r '.result.records[] | select(.SobjectType=="Opportunity") | .IsActive')
assert_eq "TC-2.7 Opportunity.New_Business record type is active" "true" "$OPP_RT_ACTIVE"

OPP_RT_BP=$(echo "$RT_JSON" | jq -r '.result.records[] | select(.SobjectType=="Opportunity") | .BusinessProcessId')
assert_not_empty "TC-2.8 Opportunity.New_Business has a Sales Process assigned" "$OPP_RT_BP"

# --- Custom Opportunity stages exist and are active ---
STAGE_JSON=$(sf data query -q "SELECT ApiName, IsActive FROM OpportunityStage" --json 2>/dev/null)
for STAGE in Discovery "Solution Validation" "Quote Sent" Negotiation; do
  ACTIVE=$(echo "$STAGE_JSON" | jq -r --arg s "$STAGE" '.result.records[] | select(.ApiName==$s) | .IsActive')
  assert_eq "TC-2.9 Opportunity stage '${STAGE}' exists and is active" "true" "$ACTIVE"
done

# --- Contact Role includes Champion ---
ROLE_VALUES=$(sf sobject describe --sobject OpportunityContactRole --json 2>/dev/null | jq -r '.result.fields[] | select(.name=="Role") | .picklistValues[].value')
assert_contains "TC-2.10 OpportunityContactRole.Role includes 'Champion'" "$ROLE_VALUES" "Champion"

# --- Validation rule: Quote Sent requires a synced Quote ---
VR_JSON=$(sf data query -q "SELECT ValidationName, Active, EntityDefinition.QualifiedApiName FROM ValidationRule WHERE ValidationName = 'Quote_Sent_Requires_Quote'" --use-tooling-api --json 2>/dev/null)
VR_ACTIVE=$(echo "$VR_JSON" | jq -r '.result.records[0].Active')
assert_eq "TC-2.11 Quote_Sent_Requires_Quote validation rule is active" "true" "$VR_ACTIVE"
VR_OBJECT=$(echo "$VR_JSON" | jq -r '.result.records[0].EntityDefinition.QualifiedApiName')
assert_eq "TC-2.12 Quote_Sent_Requires_Quote is on Opportunity" "Opportunity" "$VR_OBJECT"

# --- Collaborative Forecasting active on Opportunity Amount ---
FC_JSON=$(sf data query -q "SELECT DeveloperName, IsActive FROM ForecastingType WHERE DeveloperName = 'OpportunityAmount'" --json 2>/dev/null)
FC_ACTIVE=$(echo "$FC_JSON" | jq -r '.result.records[0].IsActive')
assert_eq "TC-2.13 Collaborative Forecasting active on Opportunity Amount" "true" "$FC_ACTIVE"

# --- Functional check: Lead conversion actually carries Target_Plan_Tier__c over
# (not just that the mapping metadata deployed) ---
CONVERTED_STATUS=$(sf data query -q "SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true LIMIT 1" --json 2>/dev/null | jq -r '.result.records[0].MasterLabel')
TEST_LEAD_ID=$(sf data create record --sobject Lead --values "LastName=RegressionCheck Company='Regression Check Co' Target_Plan_Tier__c=Growth" --json 2>/dev/null | jq -r '.result.id')

if [ -n "$TEST_LEAD_ID" ] && [ "$TEST_LEAD_ID" != "null" ]; then
  CONVERT_APEX=$(mktemp)
  cat > "$CONVERT_APEX" << EOF
Database.LeadConvert lc = new Database.LeadConvert();
lc.setLeadId('${TEST_LEAD_ID}');
lc.setConvertedStatus('${CONVERTED_STATUS}');
lc.setDoNotCreateOpportunity(false);
Database.LeadConvertResult lcr = Database.convertLead(lc);
System.debug('CONVERT_OPP_ID=' + lcr.getOpportunityId());
EOF
  CONVERT_LOG=$(sf apex run --file "$CONVERT_APEX" 2>/dev/null)
  rm -f "$CONVERT_APEX"
  # Scope to the USER_DEBUG log line specifically -- the echoed Apex source line above it
  # also contains the literal text "CONVERT_OPP_ID=" (as part of the System.debug(...) call
  # being echoed back), which would otherwise produce a spurious empty match first and
  # corrupt this capture with an embedded blank line.
  TEST_OPP_ID=$(echo "$CONVERT_LOG" | grep 'USER_DEBUG.*CONVERT_OPP_ID=' | grep -o 'CONVERT_OPP_ID=[a-zA-Z0-9]*' | cut -d= -f2)

  if [ -n "$TEST_OPP_ID" ]; then
    CARRIED_VALUE=$(sf data query -q "SELECT Target_Plan_Tier__c FROM Opportunity WHERE Id = '${TEST_OPP_ID}'" --json 2>/dev/null | jq -r '.result.records[0].Target_Plan_Tier__c')
    assert_eq "TC-2.14 Lead conversion carries Target_Plan_Tier__c to Opportunity" "Growth" "$CARRIED_VALUE"
    TEST_ACCT_ID=$(sf data query -q "SELECT AccountId FROM Opportunity WHERE Id = '${TEST_OPP_ID}'" --json 2>/dev/null | jq -r '.result.records[0].AccountId')
    sf data delete record --sobject Opportunity --record-id "$TEST_OPP_ID" --json > /dev/null 2>&1
    [ -n "$TEST_ACCT_ID" ] && [ "$TEST_ACCT_ID" != "null" ] && sf data delete record --sobject Account --record-id "$TEST_ACCT_ID" --json > /dev/null 2>&1
    # Converted Leads aren't auto-deleted by Salesforce and remain deletable via the Data API --
    # clean it up too, otherwise every regression run leaves behind one more orphaned converted Lead.
    sf data delete record --sobject Lead --record-id "$TEST_LEAD_ID" --json > /dev/null 2>&1
  else
    fail "TC-2.14 Lead conversion carries Target_Plan_Tier__c to Opportunity" "conversion did not return an Opportunity Id"
    sf data delete record --sobject Lead --record-id "$TEST_LEAD_ID" --json > /dev/null 2>&1
  fi
else
  fail "TC-2.14 Lead conversion carries Target_Plan_Tier__c to Opportunity" "could not create test Lead"
fi

# --- Must Win Opportunity checkbox + owner-only validation rule ---
MW_TYPE=$(sf sobject describe --sobject Opportunity --json 2>/dev/null | jq -r '.result.fields[] | select(.name=="Must_Win_Opportunity__c") | .type')
assert_eq "TC-2.15 Must_Win_Opportunity__c is a checkbox field" "boolean" "$MW_TYPE"

MW_FLS=$(sf data query -q "SELECT PermissionsEdit FROM FieldPermissions WHERE Field = 'Opportunity.Must_Win_Opportunity__c' AND Parent.Profile.Name = 'System Administrator'" --json 2>/dev/null | jq -r '.result.records[0].PermissionsEdit')
assert_eq "TC-2.16 Admin profile has edit FLS on Must_Win_Opportunity__c" "true" "$MW_FLS"

MW_VR_JSON=$(sf data query -q "SELECT Active, ErrorMessage FROM ValidationRule WHERE ValidationName = 'Must_Win_Owner_Only'" --use-tooling-api --json 2>/dev/null)
MW_VR_ACTIVE=$(echo "$MW_VR_JSON" | jq -r '.result.records[0].Active')
assert_eq "TC-2.17 Must_Win_Owner_Only validation rule is active" "true" "$MW_VR_ACTIVE"
MW_VR_MSG=$(echo "$MW_VR_JSON" | jq -r '.result.records[0].ErrorMessage')
assert_eq "TC-2.18 Must_Win_Owner_Only has the expected error message" "Only the Opportunity owner can set or change Must Win Opportunity." "$MW_VR_MSG"

# Functional positive case: the record owner (the authenticated CLI user, i.e. the admin)
# CAN set the checkbox on their own record.
MW_OPP_ID=$(sf data create record --sobject Opportunity --values "Name='MustWin Regression Check' StageName=Prospecting CloseDate=2026-12-31" --json 2>/dev/null | jq -r '.result.id')
if [ -n "$MW_OPP_ID" ] && [ "$MW_OPP_ID" != "null" ]; then
  MW_UPDATE_OK=$(sf data update record --sobject Opportunity --record-id "$MW_OPP_ID" --values "Must_Win_Opportunity__c=true" --json 2>/dev/null | jq -r '.result.success')
  assert_eq "TC-2.19 Opportunity owner can set Must_Win_Opportunity__c" "true" "$MW_UPDATE_OK"
  sf data delete record --sobject Opportunity --record-id "$MW_OPP_ID" --json > /dev/null 2>&1
else
  fail "TC-2.19 Opportunity owner can set Must_Win_Opportunity__c" "could not create test Opportunity"
fi
# Note: the negative case (a non-owner is blocked) can't be live-tested here -- this trial
# org has only 1 full Salesforce license, and every other active user's license type
# (Chatter Free, Integration, etc.) is rejected by the platform as an Opportunity owner
# (OP_WITH_INVALID_USER_TYPE_EXCEPTION), so there's no second real owner to test against.
# Revisit once more licenses exist (same constraint logged in Phase 1).

# --- Both custom fields are actually on the Opportunity page layout (not just FLS-granted) ---
# Re-retrieved fresh from the org each run, not read from the local tracked copy, so this
# catches a layout edit that was reverted or never deployed, not just "did we write the XML".
LAYOUT_FILE="$SCRIPT_DIR/../force-app/main/default/layouts/Opportunity-Opportunity Layout.layout-meta.xml"
sf project retrieve start --metadata "Layout:Opportunity-Opportunity Layout" --json > /dev/null 2>&1

if [ -f "$LAYOUT_FILE" ]; then
  assert_contains "TC-2.20 Must_Win_Opportunity__c is on the Opportunity page layout" "$(grep -o '<field>[A-Za-z_]*</field>' "$LAYOUT_FILE")" "<field>Must_Win_Opportunity__c</field>"
  assert_contains "TC-2.21 Target_Plan_Tier__c is on the Opportunity page layout" "$(grep -o '<field>[A-Za-z_]*</field>' "$LAYOUT_FILE")" "<field>Target_Plan_Tier__c</field>"
else
  fail "TC-2.20 Must_Win_Opportunity__c is on the Opportunity page layout" "could not retrieve layout file"
  fail "TC-2.21 Target_Plan_Tier__c is on the Opportunity page layout" "could not retrieve layout file"
fi

print_summary
exit $?
