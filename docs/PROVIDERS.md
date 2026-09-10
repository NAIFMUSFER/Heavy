# Optional provider boundaries

`server/providers/` contains server-only provider contracts. The public gateway asset allowlist excludes this directory. No actual external notification, payment, domain or storage request was made during implementation. Core notifications are still inserted transactionally into PostgreSQL by the existing commerce RPCs, and existing COD RPCs remain the financial source of truth.

| Adapter | Implementation | Production state |
|---|---|---|
| InAppProvider | Contract delegates to a trusted insertOnce repository and requires an actual persisted identifier | Existing commerce uses its transactional in-app SQL; generic adapter repository binding remains required |
| ResendEmailProvider | Concrete HTTPS adapter, explicit enable, dedicated variables, matching verified domain and enabled sending capability, timeout, safe errors and idempotency key | Disabled; verified JANA domain and dedicated key required |
| SMS / WhatsApp / Push | Named interfaces that return CONFIGURATION_REQUIRED | Provider account, consent/recipient rules and concrete adapters required |
| CodPaymentProvider | Validates SAR terms and returns awaiting_collection; capture/refund explicitly require audited database flows | Existing transactional COD workflow remains in use |
| Online PaymentProvider | Unsupported methods return CONFIGURATION_REQUIRED, including capture/refund/webhook | Approved Saudi provider and signed webhook implementation required |
| ImageStorageProvider | Missing storage returns no public image; upload/delete explicitly require configuration | Concrete storage adapter, image inspection and product-admin binding required |

The Resend implementation accepts plain-text transactional content only. It checks domain status via the fixed `https://api.resend.com/domains/{id}` endpoint before submitting to the fixed `/emails` endpoint. It rejects redirects. A provider identifier means submitted, not delivered. It never reports a failed/uncertain POST as successful and does not log provider response text, recipients, keys or message bodies. Runtime domain checks fail closed when credentials cannot read domain metadata.

Required email variables, supplied only to a future trusted notification worker:

- `JANA_EMAIL_ENABLED=true` is an explicit opt-in; unset/false leaves email disabled.
- `JANA_RESEND_API_KEY` is a dedicated JANA server-side credential.
- `JANA_RESEND_DOMAIN_ID` identifies the owner-verified JANA domain.
- `JANA_EMAIL_DOMAIN` exactly matches that domain, including any sending subdomain.
- `JANA_EMAIL_FROM` is a plain sender email at that domain.

Do not wire synchronous provider calls into quote/order transactions. Before enabling automated external notifications, add a durable PostgreSQL outbox after canonical in-app insertion. Each immutable event/recipient/channel needs a unique key, recorded attempts, lease/claim handling, dead-letter visibility and explicit retry policy. This outbox/worker is **not yet implemented**. Adapter tests inject a fixture provider transport only; they do not prove an external integration works.

Use the same provider idempotency key for retries. Resend retains it for 24 hours; this adapter refuses jobs aged 23 hours or more, requiring operator reconciliation instead of blind resend after an uncertain outcome. Persist the result before completing a job. Webhook delivery/bounce processing and unsubscribe/marketing-consent enforcement are required before any broader notification rollout. Marketing notifications are not enabled by these contracts.

Payment providers must consume server-calculated immutable order amounts, never client prices. A future adapter must validate signed provider events, persist provider_event_id uniquely, reject a mismatched order/amount/currency, and keep authorization, capture, refund and cash settlement separate. No raw card data belongs in this system. No online provider is represented as operational.

References: [Resend domain retrieval](https://resend.com/docs/api-reference/domains/get-domain), [email send and idempotency](https://resend.com/docs/api-reference/emails/send-email).
