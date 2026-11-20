# KLS Delivery Tracker

Tracks the delivery date committed to each client against the production lead time and the shipment lead time, and raises alerts when an order is at risk of missing its commitment.

- **Frontend:** a static `index.html` (no build step), hosted on Vercel
- **Backend:** Supabase (Postgres, Auth, Row Level Security, Edge Function)

## How it works

For each delivery you enter the order date, the committed delivery date, the production lead time and the shipment lead time. The app then works out:

| Field | Formula |
|---|---|
| Planned production done | order date + production LT |
| Planned delivery | order date + production LT + shipment LT |
| Latest ship-by | commitment − shipment LT |
| Committed window | commitment − order date |
| Planned buffer | commitment − planned delivery |
| Forecast delivery | uses the actual production-done, shipped or delivered dates once entered; unfinished stages are never forecast earlier than today |
| Forecast buffer | commitment − forecast delivery |

**Health:** On track · Tight (buffer below threshold) · At risk (forecast after commitment) · Late (past commitment, not delivered) · Delivered on time / late · Cancelled.

## Alerts

Alerts are calculated live by the `delivery_alerts` view:

| Alert | Severity | Trigger |
|---|---|---|
| Late | critical | Commitment date passed, not delivered |
| At risk | high | Forecast delivery after commitment |
| Production overdue | high | Planned production finish passed, no production-done date |
| Ship-by deadline | medium | Latest ship-by date within N days, or passed, and not shipped |
| Lead time exceeds commitment | medium | Production + shipment LT longer than the committed window |
| Tight buffer | low | On time, but buffer below N days |
| Due soon | low | Commitment within N days and not shipped |

Admins set the thresholds under **Settings**. Each user can acknowledge alerts. The Alerts tab shows a badge for unacknowledged critical and high alerts. Users can also turn on desktop notifications, which appear while the app is open; the app checks for new alerts every 5 minutes.

## Install as an app (PWA)

The tracker is a Progressive Web App:

- **Install:** use the *Install* banner or the *Install app* option in the user menu (Chrome, Edge, Android). On iPhone or iPad, open it in Safari, tap **Share**, then **Add to Home Screen**.
- **Offline:** the app shell is cached by `sw.js`. While you're offline, the app shows the data from the last time it loaded (stored only on that device, cleared when you sign out) and turns editing off.
- **Notifications:** new critical and high alerts trigger a system notification, sent through the service worker. The app checks every 5 minutes while it's open and whenever you return to it. Clicking a notification opens the Alerts page. On iOS, notifications work only from the installed app.
- **Updates:** when a new version is deployed, the app offers a *Reload* button. Bump `VERSION` in `sw.js` with each release.

## Users and roles

| Role | Can do |
|---|---|
| Admin | Everything: add, edit, deactivate, delete users and reset passwords; change alert settings; delete deliveries |
| Editor | Add and update deliveries |
| Viewer | Read only |

There is no public sign-up page. Admins create accounts under **Users** (handled by the `admin-users` Edge Function, which uses the service role). Deactivated users are blocked from signing in at the auth level, and RLS hides all their data. If someone signs up directly through the Supabase API, they get an *inactive viewer* profile and can see nothing.

## Project layout

```
index.html                         app (login, dashboard, deliveries, alerts, users, settings)
config.js                          Supabase URL + publishable key (public)
vercel.json                        static hosting headers
manifest.webmanifest               PWA manifest
sw.js                              service worker (offline shell, notifications)
icons/                             app icons (any + maskable, Apple touch icon)
supabase/migrations/001_init.sql   tables, RLS, views, alert logic
supabase/functions/admin-users/    admin user-management Edge Function
```

## Supabase

Project: `kls-delivery-tracker` (ref `nkqwzqwkxqexrjqchoth`, ap-southeast-1).

To recreate the backend elsewhere: run `001_init.sql`, deploy `supabase/functions/admin-users` (with JWT verification off, because the function checks the token itself), and update `config.js`. The first user created becomes the admin.
