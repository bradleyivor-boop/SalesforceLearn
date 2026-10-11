#!/usr/bin/env bash
# Phase 1 regression checks: role hierarchy, business hours, org-wide sharing defaults.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
export PATH="$HOME/.npm-global/bin:$PATH"
CURRENT_PHASE="Phase 1 - Org Baseline Setup"
echo "== ${CURRENT_PHASE} =="

# --- Role hierarchy ---
ROLES_JSON=$(sf data query -q "SELECT DeveloperName, ParentRoleId, ParentRole.DeveloperName FROM UserRole" --json 2>/dev/null)

VP_PARENT=$(echo "$ROLES_JSON" | jq -r '.result.records[] | select(.DeveloperName=="VP_Sales") | .ParentRoleId')
assert_eq "TC-1.1 VP_Sales role exists with no parent" "null" "$VP_PARENT"

MGR_PARENT=$(echo "$ROLES_JSON" | jq -r '.result.records[] | select(.DeveloperName=="Sales_Manager") | .ParentRole.DeveloperName')
assert_eq "TC-1.2 Sales_Manager reports to VP_Sales" "VP_Sales" "$MGR_PARENT"

REP_PARENT=$(echo "$ROLES_JSON" | jq -r '.result.records[] | select(.DeveloperName=="Sales_Rep") | .ParentRole.DeveloperName')
assert_eq "TC-1.3 Sales_Rep reports to Sales_Manager" "Sales_Manager" "$REP_PARENT"

# --- Admin user is assigned a role ---
ADMIN_ROLE=$(sf data query -q "SELECT UserRole.DeveloperName FROM User WHERE Profile.Name = 'System Administrator' AND IsActive = true LIMIT 1" --json 2>/dev/null | jq -r '.result.records[0].UserRole.DeveloperName')
assert_eq "TC-1.4 Admin user assigned to VP_Sales role" "VP_Sales" "$ADMIN_ROLE"

# --- Business Hours ---
BH_JSON=$(sf data query -q "SELECT MondayStartTime, MondayEndTime, FridayStartTime, FridayEndTime, TimeZoneSidKey FROM BusinessHours WHERE IsDefault = true" --json 2>/dev/null)
BH_TZ=$(echo "$BH_JSON" | jq -r '.result.records[0].TimeZoneSidKey')
assert_eq "TC-1.5 Default business hours timezone is Europe/London" "Europe/London" "$BH_TZ"

BH_MON_START=$(echo "$BH_JSON" | jq -r '.result.records[0].MondayStartTime')
assert_eq "TC-1.6 Monday start time is 09:00" "09:00:00.000Z" "$BH_MON_START"

BH_FRI_END=$(echo "$BH_JSON" | jq -r '.result.records[0].FridayEndTime')
assert_eq "TC-1.7 Friday end time is 17:00" "17:00:00.000Z" "$BH_FRI_END"

# --- Org-Wide Defaults (sharing model) ---
OWD_JSON=$(sf data query -q "SELECT QualifiedApiName, InternalSharingModel FROM EntityDefinition WHERE QualifiedApiName IN ('Account','Opportunity','Case')" --use-tooling-api --json 2>/dev/null)
for OBJ in Account Opportunity Case; do
  MODEL=$(echo "$OWD_JSON" | jq -r --arg o "$OBJ" '.result.records[] | select(.QualifiedApiName==$o) | .InternalSharingModel')
  assert_eq "TC-1.8 ${OBJ} org-wide default is Private" "Private" "$MODEL"
done

print_summary
exit $?
