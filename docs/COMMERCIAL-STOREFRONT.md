# Merchant identity, policy versions and admission

The first commercial rollout is a single warehouse operation. Production starts with new quote creation closed and no published merchant profile. This migration does not cancel orders, expire existing quotes, edit merchandise, adjust inventory or write cash entries.

An administrator uses **إعدادات المتجر** to save a private draft, explicitly publish an immutable policy version, and separately open or pause new orders. The profile contains merchant display/legal names, registration type/number, business address, customer support contact/hours, owner-declared tax status, and owner-authored sales/privacy/delivery/returns policies. All published versions remain available by UUID. These fields record the owner's declaration; the application does not verify registrations or legal compliance.

Each newly created quote freezes the published version ID and seller identity into its snapshot. Confirmation retains that snapshot in the original order terms. The web and mobile quote review load the matching immutable policies before enabling confirmation. Publication of a later version cannot alter an earlier contract. A new policy version can now be published only while admission is closed; the owner then records a fresh opening review for that version. Closing admission blocks fresh reservations; already-reserved valid quotes and their idempotent retries remain usable. Fulfillment, customer service and collection continue for existing orders.

Opening requires a published profile, an owner-declared supported tax status, no active products marked as preview/demo in their descriptions, at least one available product, an available delivery slot, healthy stock/cash/capacity invariants, and an explicit recorded operations attestation/reference. This is an initial opening gate, not a promise of perpetual stock or delivery availability; checkout still checks each reservation. Changing product data after opening remains a controlled administrator operation and must follow the launch process.

VAT-registered merchant profiles may be saved and published while paused. Opening such a store is blocked: a VAT calculation and tax invoice integration is not yet implemented. The supported opening mode is an owner-declared non-VAT-registered merchant. Do not choose this mode for the owner or describe it as tax authority verification. Publishing a registered profile while open is rejected.

The customer cash-collection receipt does not change this boundary. It records actual cash received against the frozen order terms and completed refunds, labels itself as non-tax, and must not be presented as a VAT invoice or as registration/compliance evidence.

Administrative writes require a persisted idempotency key and the current revision. A row lock serializes publication/admission updates against quotes. The administrative read derives the latest successful opening attestation from the immutable audit ledger and shows its time, responsible employee, reference and five accepted checks. It also states whether that record belongs to the currently published policy. The shareable launch observation includes only the record time and policy-match flag, never the internal reference or employee identity. Public RPCs expose only published profiles, never draft text, acceptance details or publisher IDs. Client database roles have no direct execute grants; the trusted Edge uses the existing JANA opaque-session authorization.

## Photos

Product versions already store `image_url`; web and native catalog/detail views now display it. Only HTTPS URLs without embedded credentials are accepted by the UI. The browser image request uses no referrer; a failed image falls back to the product symbol. Web image loading is allowed for HTTPS only on the storefront page; no server image fetch proxy was added. Store owners supply actual product photographs and appropriate hosting. A media upload service is not included in this change.

## Owner launch inputs

1. Actual legal identity, registration, public support contacts/hours and approved policy text.
2. Confirmed tax status and any required invoicing integration.
3. Real merchandise, prices/photos, warehouse receipt/inspection/count records, delivery coverage and capacity, and assigned staff.
4. Approved backup/restore procedure with a measured isolated restore, production hosting/staging, verified communication providers, and a support recovery process.
5. Customer/staff acceptance and physical-device checks. Native debug/simulator builds are engineering evidence, not signed app-store releases.

Do not create production test orders to establish readiness or convert preview merchandise into real stock without source records. The launch settings cannot substitute for warehouse inspections or provider/owner approvals.

## Verification

`tests/storefront.py` checks roles, draft privacy, validation, immutable historical publication, visible opening evidence, policy/acceptance continuity, frozen quote/order seller identity, closure, existing-quote confirmation, unsupported tax status, preview products, operations attestation, concurrent retries/publications/closure, private helper grants and final invariants. `tests/storefront_fixture.py` configures an explicitly fake store only after the bootstrap enforces a disposable loopback database. No test profile or opening acceptance is included in the production migration.

Browser acceptance covers admin publication/pause/reopen, guest access, quote-bound policy loading and confirmation, followed by the existing operational journey. RPC argument contracts use the actual restored PostgreSQL schema. Source and deployment evidence belong in `RELEASE-EVIDENCE.md` after the gates complete.
