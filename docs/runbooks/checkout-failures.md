# Runbook: checkout failures (lift tickets or rentals breaching their SLO)

**Alert:** `SLO_WATCH` opens incidents in `SKI_OBS.OPS.INCIDENTS` when a service's error rate is above its objective for 5 minutes.
**Owner:** Guest Commerce, with Payments on call for anything below.

## 1. Confirm the impact (2 minutes)
- Ops app → **Service health**. Which services are breaching? Is notifications quiet? (Quiet notifications means purchases stopped, not that email is broken.)
- Check traffic: is this a demand spike (powder day, holiday) or normal traffic?

## 2. Find where time goes (5 minutes)
- **Saturation chart.** If payment requests waiting for a provider connection are above the pool size (8), the pool is exhausted. Go to step 3.
- **Traces tab → Failed.** Open a failed checkout. A long `provider.pool.wait` span means waiting for a connection; a long `provider.charge` span means the provider itself is slow.
- **Logs tab.** Search `timed out` and `provider`.
- Optional: **Incidents → Write the AI summary** for a first draft. Check its reasoning against the charts before sharing it.

## 3. Mitigate
| What you see | Do this |
|---|---|
| Provider slow (`provider.charge` long), demand normal | Check the provider's status page; open a ticket with alpine-pay. Consider failing over to the backup provider. |
| Demand far above normal, provider normal | Scale payments out (each replica brings its own pool of 8): `kubectl -n summit-peak scale deploy/payments --replicas=3`. |
| Both (the powder-day case) | Scale payments out **and** escalate to the provider. Scaling alone multiplies pressure on a struggling provider. |

## 4. Recover and close
- Errors should fall within a minute of the fix. The incident resolves itself after 5 healthy minutes.
- Within 2 business days: a post-incident review. Start from the AI summary, correct it, and record what it got wrong.

## Known follow-ups from the first incident (Nov 24)
- Callers time out at 2.0 s but payments waits up to 2.5 s, so some charges succeed after the guest was told they failed. Callers should wait longer than payments, or payments should stop sooner.
- Add a circuit breaker so payments fails fast when the queue passes the pool size.
- Alert on pool saturation directly, before errors start.
