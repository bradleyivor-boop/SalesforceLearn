#!/usr/bin/env bash
# Phase 3 regression checks: Legal Entity, Product Catalog structure, SaaS product set,
# attributes, bundle, selling models, and pricing across Standard + Annual Prepay price books.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
export PATH="$HOME/.npm-global/bin:$PATH"
CURRENT_PHASE="Phase 3 - Revenue Cloud / RLM Foundation"
echo "== ${CURRENT_PHASE} =="

# --- Legal Entity ---
LE_STATUS=$(sf data query -q "SELECT Status FROM LegalEntity WHERE Name = 'Acme SaaS Inc.'" --json 2>/dev/null | jq -r '.result.records[0].Status')
assert_eq "TC-3.1 Legal Entity 'Acme SaaS Inc.' exists and is Active" "Active" "$LE_STATUS"

# --- Catalog + Categories ---
CATALOG_ID=$(sf data query -q "SELECT Id FROM ProductCatalog WHERE Name = 'SaaS Product Catalog'" --json 2>/dev/null | jq -r '.result.records[0].Id')
assert_not_empty "TC-3.2 SaaS Product Catalog exists" "$CATALOG_ID"

CAT_COUNT=$(sf data query -q "SELECT COUNT(Id) cnt FROM ProductCategory WHERE CatalogId = '${CATALOG_ID}'" --json 2>/dev/null | jq -r '.result.records[0].cnt')
assert_eq "TC-3.3 Catalog has 2 categories (Subscriptions, Usage Add-ons)" "2" "$CAT_COUNT"

# --- Products exist with correct codes/types ---
PRODUCTS_JSON=$(sf data query -q "SELECT Name, ProductCode, Type, UsageModelType, IsActive FROM Product2 WHERE ProductCode LIKE 'SAAS-%'" --json 2>/dev/null)
PRODUCT_COUNT=$(echo "$PRODUCTS_JSON" | jq -r '.result.totalSize')
assert_eq "TC-3.4 All 6 SaaS products exist" "6" "$PRODUCT_COUNT"

GROWTH_TYPE=$(echo "$PRODUCTS_JSON" | jq -r '.result.records[] | select(.ProductCode=="SAAS-GROWTH") | .Type')
assert_eq "TC-3.5 Growth Plan is a Bundle product" "Bundle" "$GROWTH_TYPE"

API_USAGE_MODEL=$(echo "$PRODUCTS_JSON" | jq -r '.result.records[] | select(.ProductCode=="SAAS-API-USAGE") | .UsageModelType')
assert_eq "TC-3.6 API Usage Add-on has a usage model (Commit)" "Commit" "$API_USAGE_MODEL"

ALL_ACTIVE=$(echo "$PRODUCTS_JSON" | jq -r '[.result.records[].IsActive] | all')
assert_eq "TC-3.7 All 6 SaaS products are active" "true" "$ALL_ACTIVE"

# --- Category assignment ---
USAGE_CAT_COUNT=$(sf data query -q "SELECT COUNT(Id) cnt FROM ProductCategoryProduct WHERE Product.ProductCode = 'SAAS-API-USAGE' AND ProductCategory.Name = 'Usage Add-ons'" --json 2>/dev/null | jq -r '.result.records[0].cnt')
assert_eq "TC-3.8 API Usage Add-on is categorized under Usage Add-ons" "1" "$USAGE_CAT_COUNT"

SUBS_CAT_COUNT=$(sf data query -q "SELECT COUNT(Id) cnt FROM ProductCategoryProduct WHERE Product.ProductCode LIKE 'SAAS-%' AND ProductCategory.Name = 'Subscriptions'" --json 2>/dev/null | jq -r '.result.records[0].cnt')
assert_eq "TC-3.9 5 products categorized under Subscriptions" "5" "$SUBS_CAT_COUNT"

# --- Product Attributes ---
SEAT_ATTR_JSON=$(sf data query -q "SELECT Status, DefaultValue FROM ProductAttributeDefinition WHERE Product2.ProductCode = 'SAAS-ENTERPRISE' AND AttributeDefinition.Name = 'Seat Count'" --json 2>/dev/null)
SEAT_ATTR_STATUS=$(echo "$SEAT_ATTR_JSON" | jq -r '.result.records[0].Status')
assert_eq "TC-3.10 Enterprise Plan has an active Seat Count attribute" "Active" "$SEAT_ATTR_STATUS"

SUPPORT_ATTR_JSON=$(sf data query -q "SELECT Status FROM ProductAttributeDefinition WHERE Product2.ProductCode = 'SAAS-PREMIUM-SUPPORT' AND AttributeDefinition.Name = 'Support Tier'" --json 2>/dev/null)
SUPPORT_ATTR_STATUS=$(echo "$SUPPORT_ATTR_JSON" | jq -r '.result.records[0].Status')
assert_eq "TC-3.11 Premium Support Add-on has an active Support Tier attribute" "Active" "$SUPPORT_ATTR_STATUS"

# --- Bundle: Growth Plan -> optional Premium Support Add-on ---
BUNDLE_JSON=$(sf data query -q "SELECT ChildProduct.Name, IsComponentRequired, Quantity FROM ProductRelatedComponent WHERE ParentProduct.ProductCode = 'SAAS-GROWTH'" --json 2>/dev/null)
BUNDLE_CHILD=$(echo "$BUNDLE_JSON" | jq -r '.result.records[0].ChildProduct.Name')
assert_eq "TC-3.12 Growth Plan bundles Premium Support Add-on" "Premium Support Add-on" "$BUNDLE_CHILD"
BUNDLE_REQUIRED=$(echo "$BUNDLE_JSON" | jq -r '.result.records[0].IsComponentRequired')
assert_eq "TC-3.13 Premium Support bundle component is optional" "false" "$BUNDLE_REQUIRED"

# --- Pricing: Standard Price Book (monthly, one-time, usage, and annual list) ---
# Note: plain "CODE:PRICE" pairs, not `declare -A`, for compatibility with macOS's stock
# bash (3.2, pre-GPLv3) which doesn't support associative arrays.
STANDARD_MONTHLY="SAAS-STARTER:49 SAAS-GROWTH:149 SAAS-ENTERPRISE:499 SAAS-PREMIUM-SUPPORT:99"
for PAIR in $STANDARD_MONTHLY; do
  CODE="${PAIR%%:*}"
  EXPECTED="${PAIR##*:}"
  PRICE=$(sf data query -q "SELECT UnitPrice FROM PricebookEntry WHERE Product2.ProductCode = '${CODE}' AND Pricebook2.IsStandard = true AND ProductSellingModel.SellingModelType = 'Evergreen'" --json 2>/dev/null | jq -r '.result.records[0].UnitPrice')
  assert_eq "TC-3.14 Standard monthly price for ${CODE}" "${EXPECTED}" "$PRICE"
done

USAGE_PRICE=$(sf data query -q "SELECT UnitPrice FROM PricebookEntry WHERE Product2.ProductCode = 'SAAS-API-USAGE' AND Pricebook2.IsStandard = true" --json 2>/dev/null | jq -r '.result.records[0].UnitPrice')
assert_eq "TC-3.15 API Usage Add-on priced at 0.05/unit" "0.05" "$USAGE_PRICE"

IMPL_PRICE=$(sf data query -q "SELECT UnitPrice FROM PricebookEntry WHERE Product2.ProductCode = 'SAAS-IMPL-FEE' AND Pricebook2.IsStandard = true" --json 2>/dev/null | jq -r '.result.records[0].UnitPrice')
assert_eq "TC-3.16 Implementation Fee priced as one-time 500" "500" "$IMPL_PRICE"

# --- Pricing: Annual Prepay custom price book (discounted vs. 12x monthly) ---
ANNUAL_PREPAY="SAAS-STARTER:490 SAAS-GROWTH:1490 SAAS-ENTERPRISE:4990 SAAS-PREMIUM-SUPPORT:990"
for PAIR in $ANNUAL_PREPAY; do
  CODE="${PAIR%%:*}"
  EXPECTED="${PAIR##*:}"
  PRICE=$(sf data query -q "SELECT UnitPrice FROM PricebookEntry WHERE Product2.ProductCode = '${CODE}' AND Pricebook2.Name = 'Annual Prepay'" --json 2>/dev/null | jq -r '.result.records[0].UnitPrice')
  assert_eq "TC-3.17 Annual Prepay price for ${CODE} is discounted vs. 12x monthly" "${EXPECTED}" "$PRICE"
done

ANNUAL_PB_ACTIVE=$(sf data query -q "SELECT IsActive FROM Pricebook2 WHERE Name = 'Annual Prepay'" --json 2>/dev/null | jq -r '.result.records[0].IsActive')
assert_eq "TC-3.18 Annual Prepay price book is active" "true" "$ANNUAL_PB_ACTIVE"

print_summary
exit $?
