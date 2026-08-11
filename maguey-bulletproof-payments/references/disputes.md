# Stripe Disputes (Chargebacks) — Reference

A customer's bank initiates a dispute. Stripe holds or withdraws the funds and notifies the webhook via `charge.dispute.created`. The response window is short (typically 7–21 days depending on the card network). Ignoring a dispute means automatic loss of funds.

This file is the reference for the dispute handler pattern. The top-level skill flags it as a known gap; use this document when the user approves building it.

## Why disputes are a first-class concern

- **Money-moving:** Stripe removes the disputed amount from the balance on dispute creation. The merchant has to win the dispute to get it back.
- **Time-bounded:** Response deadlines are set by the card network, not the business. Missing them auto-loses.
- **Regulatory trail:** Disputes create customer records that affect Stripe processor standing. High dispute-rate triggers review or account suspension.
- **Different from refunds:** A refund is the merchant choosing to return money. A dispute is the customer/bank forcing it. Handling is separate.

## Events to handle

| Event | When it fires | Handler responsibility |
|---|---|---|
| `charge.dispute.created` | Customer/bank opens a dispute | Mark order `disputed`, freeze ticket scanning, alert owner, log evidence window |
| `charge.dispute.updated` | Status changes (evidence submitted, won, lost) | Update order metadata with status transitions |
| `charge.dispute.closed` | Dispute resolved | If `status === 'won'`, restore order to `paid`. If `lost`, treat as refunded (status `refunded_dispute`). |
| `charge.dispute.funds_withdrawn` | Stripe pulls funds from balance | Log to `revenue_discrepancies` — immediate revenue impact |
| `charge.dispute.funds_reinstated` | Funds returned after won dispute | Log reversal to `revenue_discrepancies` |

## Recommended handler skeleton

Place after `charge.refunded` in `stripe-webhook/index.ts`. Use the same order-resolution pattern (`orders.payment_reference` → `vip_reservations.stripe_payment_intent_id`).

```typescript
if (event.type === "charge.dispute.created") {
  const dispute = event.data.object;
  const paymentIntentId = dispute.payment_intent as string | null;

  logger.warn("charge.dispute.created received", {
    disputeId: dispute.id,
    paymentIntentId,
    amount: dispute.amount,
    reason: dispute.reason,
    evidenceDueBy: dispute.evidence_details?.due_by,
  });

  if (!paymentIntentId) return; // nothing to reconcile

  const { data: order } = await supabase
    .from("orders")
    .select("id, metadata")
    .eq("payment_reference", paymentIntentId)
    .maybeSingle();

  if (order) {
    await supabase.from("orders").update({
      status: "disputed",
      metadata: {
        ...((order.metadata as Record<string, unknown>) ?? {}),
        dispute: {
          stripe_dispute_id: dispute.id,
          reason: dispute.reason,
          amount: dispute.amount,
          status: dispute.status,
          evidence_due_by: dispute.evidence_details?.due_by,
          created_at: new Date().toISOString(),
        },
      },
    }).eq("id", order.id);

    // Freeze tickets — do not refund them (dispute may be won)
    await supabase.from("tickets")
      .update({ status: "disputed" })
      .eq("order_id", order.id);

    // Log revenue impact
    await supabase.from("revenue_discrepancies").insert({
      db_revenue: dispute.amount / 100,
      stripe_revenue: 0,
      discrepancy_amount: dispute.amount / 100,
      metadata: {
        reason: "dispute_created",
        order_id: order.id,
        stripe_dispute_id: dispute.id,
        evidence_due_by: dispute.evidence_details?.due_by,
      },
    });

    // Alert owner — this needs human action before the deadline.
    // Delegate to maguey-bulletproof-email for the actual notification.
  }
}
```

## Status model contract

Introducing `status = 'disputed'` on `orders` and `tickets` requires:

1. **Scanner update** (cross-skill, `maguey-bulletproof-scanner`): reject `status === 'disputed'` tickets at the door. A disputed charge should NOT admit the customer; if the dispute is lost later, they got in for free.
2. **Dashboard update** (cross-skill): disputed orders need a dedicated view so the owner sees the evidence-due deadline.
3. **Email alert** (cross-skill, `maguey-bulletproof-email`): owner notification with dispute ID, deadline, and evidence-submission link.

Do not ship the dispute handler without at least #1 and #3. A dispute that admits customers AND fails silently is worse than no handler.

## What NOT to do

- **Don't auto-refund.** A dispute can be won. If the code issues a refund in parallel with the dispute, the customer gets money from both channels (the refund AND the dispute withdrawal).
- **Don't mark tickets refunded.** Different state. Use `disputed`.
- **Don't close the order.** Keep `orders.status = 'disputed'` until `charge.dispute.closed` arrives, then transition based on `status === 'won'` or `'lost'`.
- **Don't skip the 7-day alarm.** The response window is the whole reason this handler exists.

## When the user asks to ship this

Before writing any code:
1. Confirm the user understands the cross-skill dependencies (scanner, email, dashboard).
2. Decide status semantics: fresh value `'disputed'` or reuse `'refunded'`? Recommend `'disputed'` — they behave differently.
3. Verify `evidence_details.due_by` gets surfaced to the owner via an existing alerting channel, or deferred until the email skill adds that template.
4. Check Stripe Dashboard endpoint config: `charge.dispute.created`, `charge.dispute.closed`, `charge.dispute.funds_withdrawn` must be enabled.

Defer to the skill's hard rules: branch workflow, no direct-to-main, test with `stripe trigger charge.dispute.created` via Stripe CLI before deploy.
