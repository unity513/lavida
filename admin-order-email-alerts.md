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

### 1. Apply the database migration

Run `supabase/migrations/202610120001_admin_order_email_alerts.sql`. It creates
the tables, the triggers, the recipient console RPCs and the cron dispatcher.

### 2. Deploy the email worker

Deploy the Edge Function `supabase/functions/send-admin-alert-email`.

### 3. Set the worker secrets

| Secret | Purpose |
| --- | --- |
| `ADMIN_ALERT_EMAIL_PROVIDER` | `resend` (default), `sendgrid` or `postmark` |
| `ADMIN_ALERT_EMAIL_API_KEY` | Provider API key |
| `ADMIN_ALERT_FROM_EMAIL` | Verified sender, e.g. `info@lavida.agency` |
| `ADMIN_ALERT_FROM_NAME` | Sender display name |
| `ADMIN_ALERT_REPLY_TO` | Optional reply-to address |
| `ADMIN_ALERT_WORKER_SECRET` | Shared secret used by the dispatcher |

Never place provider keys in frontend JavaScript.

### 4. Store the dispatch secret and worker URL

In the database vault, create a secret named:

```
lavida_admin_alert_worker_secret
```

with the same value as `ADMIN_ALERT_WORKER_SECRET`. Then open the console and
fill in **Email Worker URL**:

```
https://<project-ref>.supabase.co/functions/v1/send-admin-alert-email
```

### 5. Send something to confirm

Place a test order, or press **Send Queued Emails Now** in the console, then
check **Recent Email Activity** for `sent` status.

## Delivery safety

- Alert emails are queued in `admin_alert_email_queue`, so a provider outage
  never blocks an order.
- Failed sends retry up to three times, then stop with the provider error saved.
- A cron job (`lavida-admin-alert-email-worker`, every minute) sweeps the queue,
  and each alert also tries an immediate dispatch so emails normally leave at
  once.
- `admin_alert_log` keeps a record of every order event that raised an alert.
