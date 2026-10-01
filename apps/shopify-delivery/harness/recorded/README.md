# Recorded payloads

`orders-create.template.json` is the body shape the fake Shopify sends in CI. The fake
overwrites the id, GID, name, timestamps and cancellation fields per order; everything
else comes from this file.

Provenance is stated in the file's `_provenance` field. The first version was synthetic,
written before the development store existed. After run R1 it is replaced by a capture
from the development store, scrubbed by `harness/export-capture.ts`: order and checkout
tokens, the order status URL, browser IP and any customer fields are removed or replaced,
and the HMAC header is never stored here (CI re-signs with a dummy secret).
