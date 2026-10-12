# LAVIDA Admin Order Alert Emails

Every new order now raises an alert email, and you decide inside the app which
admins receive it. No code changes are needed to add or remove recipients.

## What triggers an alert

| Event | Alert |
| --- | --- |
| New marketplace order (includes crypto orders) | New Marketplace Order |
| Marketplace order status / payment status change | Marketplace Order Updated |
| New printing order | New Printing Order |
| Printing order production / payment change | Printing Order Updated |
| New professional service request | New Service Request |

Each alert queues one email per assigned recipient, and also drops an in-app
notification in their notifications centre.

## Managing recipients (in the app)

Open **Order Alert Emails** from the admin menu:

- `admin-alerts-admin.html` (direct link)
- Linked from Notifications Admin, Orders Management and the Account admin tools

What you can do there:

- **Add recipient** - any admin/staff email address.
- **Order Alerts on/off** - per recipient, without removing them.
- **Active / Paused** - temporarily stop emails for a recipient.
- **Can manage list** - let a trusted admin edit the recipient list too.
- **Remove** - delete a recipient permanently.

`giyanichirwa@gmail.com` is seeded as the **Super Admin**: it always receives
alerts, can always manage the list, and cannot be removed.

## Who can open the console

- The super admin address, and
- recipients flagged *Can manage list*, and
- any active staff role `owner`, `admin`, `executive`, `manager` or `notification_admin`.

## Required setup (one time)

### 1. Apply the database migrations

Run all three migrations, in order:

1. `supabase/migrations/202610120001_admin_order_email_alerts.sql`
2. `supabase/migrations/202610120002_admin_alert_email_automation.sql`
3. `supabase/migrations/202610120003_admin_alert_never_blocks_orders.sql`

The first creates the tables, triggers, console RPCs and cron dispatcher. The
second adds the self-configuring helpers so the sender connection can be
finished from inside the console with one button. The third makes order
checkout immune to any alert problem: if alerting ever fails, the order still
goes through and the failure is logged instead of stopping the app.

### 2. Deploy the email worker

Deploy the Edge Function `supabase/functions/send-admin-alert-email`.

### 3. Set the worker secrets

The accounts email is used as the default sender, so a plain Gmail setup works
with no domain verification step.

| Secret | Purpose |
| --- | --- |
| `ADMIN_ALERT_EMAIL_PROVIDER` | `resend` (default), `sendgrid` or `postmark` |
| `ADMIN_ALERT_EMAIL_API_KEY` | Provider API key |
| `ADMIN_ALERT_FROM_EMAIL` | Sender address, e.g. `giyanichirwa@gmail.com` |
| `ADMIN_ALERT_FROM_NAME` | Sender display name |
| `ADMIN_ALERT_REPLY_TO` | Optional reply-to address |
| `ADMIN_ALERT_WORKER_SECRET` | Shared secret used by the dispatcher (any long random string) |

Never place provider keys in frontend JavaScript.

### 4. Finish the sender connection (one button)

Open **Order Alert Emails** in the app and press **Finish Email Setup**. That
button derives and stores the worker URL and connects the shared secret, so
there is nothing to copy into the database by hand. The status banner at the
top of the settings panel turns green when it is ready.

If you ever rotate `ADMIN_ALERT_WORKER_SECRET`, press the button again.

### 5. Send something to confirm

Place a test order, or press **Send Queued Emails Now** in the console, then
check **Recent Email Activity** for `sent` status.

If anything looks stuck, press **Check System**. It reports the worker address,
the shared secret, recipient count, whether alerts are switched on, the
queue/sent/failed counts, and the last few order events — including any that
were skipped and why.

## Delivery safety

- Alert emails are queued in `admin_alert_email_queue`, so a provider outage
  never blocks an order.
- Failed sends retry up to three times, then stop with the provider error saved.
- A cron job (`lavida-admin-alert-email-worker`, every minute) sweeps the queue,
  and each alert also tries an immediate dispatch so emails normally leave at
  once.
- `admin_alert_log` keeps a record of every order event that raised an alert.
