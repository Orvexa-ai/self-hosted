# Sweeper Self-Hosted

> **Version**: v1.1.99  
> AI Workforce OS, purpose-built for Australian accounting firms — document normalisation, compliance coding, workpaper preparation, client collaboration, and professional sign-off. Self-hosted edition.

> **Requires a Sweeper Enterprise license.**  
> Register at [enterprise.sweeper-acct.com.au](https://enterprise.sweeper-acct.com.au)

---

## What you get

- Sweeper frontend running on your own server
- All client data, workpapers, and audit logs stay within your own Supabase project - Sweeper never holds a copy
- AI processing (data normalization, workpaper preparation, client collaboration, audit trails, and professional sign-off) via your Sweeper MCP API key
- You own your data - build downstream integrations (Xero, MYOB, QuickBooks) directly from your Supabase Storage using any tool you choose
- Upgrade by pulling the latest Docker image - no rebuild required

## Architecture

```
Your server
  frontend       nginx + React SPA (sweeper425/sweeper-frontend)

Your Supabase project
  Postgres + RLS   all firm/client/case data
  Auth             JWT authentication
  Storage          bank statement PDFs, workpaper CSVs and JSON

Sweeper backend    enterprise.sweeper-acct.com.au
  AI processing via your MCP API key
  (data normalization, workpaper preparation, client collaboration,
   audit trails, and professional sign-off)

Your downstream integrations (Xero, MYOB, QuickBooks, etc.)
  Your Supabase Storage and database are yours to query directly.
  Read workpaper files and BAS data from your own storage,
  then push to any accounting software using your own credentials.
```

The frontend image is public on Docker Hub - **no Docker Hub login required**.

---

## Your data

All client data, workpapers, and audit logs are written to **your own Supabase project** - Sweeper never holds a copy.

Once a BAS/GST folder is certified, the output files sit in your own Supabase Storage:

```
{firm_id}/{client_id}/{period}/
  final/     - BAS summary JSON (G1, G11, 1A, 1B, 8A) - written after BAS draft
  reviewed/  - GST-coded transaction workpaper CSV - human-certified by Senior
  archived/  - Immutable copy written after Partner certifies
```

You can query these files directly using the Supabase client, the Supabase dashboard, or any PostgreSQL-compatible tool. Build downstream integrations with Xero, MYOB, QuickBooks, or any other platform using your own credentials and your own schedule - no dependency on Sweeper for that step.

---

---

## Prerequisites

| Requirement | Minimum |
|---|---|
| Docker Engine | 24+ |
| Docker Compose | v2 (bundled with Docker Desktop) |
| RAM | 1 GB |
| OS | Linux, macOS, Windows |

---

## Quick start

### 1. Create a Supabase project

Create a free project at [supabase.com](https://supabase.com) ->choose **ap-southeast-2 (Sydney)** region.

From **Settings ->API**, copy:
- Project URL
- `anon` / public key

### 2. Apply the database schema

In Supabase **SQL Editor**, paste and run `combined_schema.sql` (included in this release).

```
Supabase Dashboard ->SQL Editor ->New query ->paste combined_schema.sql ->Run
```

### 3. Create the Storage buckets

Two buckets are required. In Supabase **Dashboard - Storage - New bucket**, create each:

**Bucket 1 - workpaper files** (auto-created on first registration, but create manually if registering outside the UI):
- **Name:** `firm-{your-firm-uuid}` - replace with your firm's UUID from the `firms` table after registration
- **Public:** off (private)

**Bucket 2 - client query attachments** (must be created manually before clients can attach receipts):
- **Name:** `client-uploads`
- **Public:** off (private)

After creating `client-uploads`, add Storage policies in **Dashboard - Storage - Policies - client-uploads**:

| Policy | Allowed roles |
|---|---|
| INSERT | `anon`, `authenticated` |
| SELECT | `anon`, `authenticated` |
| DELETE | `authenticated` |

Or run this SQL in the SQL Editor:
```sql
CREATE POLICY "client_uploads_insert" ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'client-uploads');
CREATE POLICY "client_uploads_select" ON storage.objects FOR SELECT
  USING (bucket_id = 'client-uploads');
CREATE POLICY "client_uploads_delete" ON storage.objects FOR DELETE
  USING (bucket_id = 'client-uploads' AND auth.role() = 'authenticated');
```

### 4. Configure the JWT Auth Hook

This step injects `firm_id`, `team_id`, and `user_role` into every JWT so the backend can authenticate requests without an extra database round-trip.

In your Supabase project ->**Authentication ->Auth Hooks**:

1. Click **Add new hook**
2. Hook type: **Customize Access Token**
3. Function name: `custom_jwt_hook`
4. Click **Save**

> **Optional but recommended.** Without the hook, authentication still works ->the backend falls back to a database lookup on every request. With the hook, claims are in the JWT itself (faster, fewer round-trips).

### 5. Configure environment

```bash
cp .env.example .env
```

Fill in:

| Variable | Value |
|---|---|
| `VITE_SUPABASE_URL` | Your Supabase project URL |
| `VITE_SUPABASE_ANON_KEY` | Supabase anon key |
| `SWEEPER_MCP_KEY` | Your Sweeper MCP API key from [enterprise.sweeper-acct.com.au](https://enterprise.sweeper-acct.com.au) |
| `SWEEPER_VERSION` | `1.1.99` (or leave default) |

### 6. Configure Supabase Auth redirect URLs

In your Supabase project ->**Authentication ->URL Configuration**:
- **Site URL**: `http://localhost:3000` (or your domain)
- **Redirect URLs**: `http://localhost:3000/**`

### 7. Start

```bash
docker compose pull
docker compose up -d
docker compose logs -f frontend
```

Frontend should show `ready` within a few seconds:

```
NAME        STATUS
frontend    running
```

Open `http://localhost:3000` ->the registration page creates the first Owner account and firm.

---

## Production setup

### Reverse proxy (nginx)

```nginx
server {
    listen 443 ssl;
    server_name sweeper.firm.com.au;

    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host $host;
    }
}
```

### Cloudflare (recommended)

Point your domain's A record to your server IP. Enable **Full (strict)** SSL mode.

---

## Upgrading

```bash
# 1. Apply the new combined_schema.sql in Supabase SQL Editor (idempotent ->safe to re-run)

# 2. Update SWEEPER_VERSION in .env

# 3. Pull and restart
docker compose pull
docker compose up -d --force-recreate
```

---

## Configuration reference

| Variable | Required | Purpose |
|---|---|---|
| `VITE_SUPABASE_URL` | Yes | Supabase project URL |
| `VITE_SUPABASE_ANON_KEY` | Yes | Supabase anon key |
| `SWEEPER_MCP_KEY` | Yes | MCP API key from enterprise.sweeper-acct.com.au - enables AI Normalization, workpaper preparation, client collaboration, audit trails, and professional sign-off. |
| `VITE_APP_NAME` | No | Display name (default: `Sweeper`) |
| `VITE_CONTACT_EMAIL` | No | Support email shown in UI |
| `SWEEPER_VERSION` | No | Image version to pull (default: `1.1.99`) |
| `FRONTEND_PORT` | No | Host port (default: `3000`) |

---

## Account setup notes

**Each email address can only be linked to one account.**

Supabase Auth enforces unique emails across all roles. If the firm principal (Owner) also manages their own partner team, they must register their team account with a different email address.

A common pattern is to use email sub-addressing (supported by most providers including Gmail):

| Role | Email example |
|---|---|
| Owner (firm admin) | `principal@firm.com.au` |
| Partner (own team) | `principal+partner@firm.com.au` |
| Junior | `junior@firm.com.au` |

Both `principal@firm.com.au` and `principal+partner@firm.com.au` deliver to the same inbox ->Supabase treats them as separate accounts.

---

## Troubleshooting

**Frontend shows blank page or "missing Supabase URL"**

Check that `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` are set in `.env`.  
The frontend reads these at container start ->no rebuild needed. After changing `.env`:

```bash
docker compose up -d frontend
```

**Cannot log in / auth errors**

Confirm Supabase Auth **Site URL** and **Redirect URLs** match your frontend URL.

**Supabase Security Advisor shows warnings after applying the schema**

Some warnings are expected and don't need any action:

- A few "Public can execute" warnings — these belong to the client magic-link
  feature, where a client has no login account and proves identity with a
  one-time token + password instead. Those functions must be reachable
  without signing in by design.
- Most "Signed-in users can execute" warnings — a number of functions run
  with elevated database permissions so they can safely perform actions
  across team boundaries (e.g. adding a team member, moving a client between
  groups). Each one checks the caller's firm/team ownership before doing
  anything, so the elevated permission is scoped to that single action.
- "Leaked Password Protection Disabled" — a Supabase paid-plan feature,
  unrelated to Sweeper.

If you see a *different* warning not covered above, treat it as worth
investigating.

---

## Support

- **Email**: service@sweeper-acct.com.au
- **Response time**: next business day (AEST / AEDT)
- **Docs**: [enterprise.sweeper-acct.com.au](https://enterprise.sweeper-acct.com.au)

---

© 2026 PIN ME PTY LTD. All rights reserved.

---

## Changelog

### v1.1.99 (October 2026)
- Update: sign-in, FAQ and Privacy Policy wording refreshed
- Database: `combined_schema.sql` updated for Supabase's October 2026 access change

### Database schema update (September 2026, no image version change)
- Security: hardened `combined_schema.sql` — closed a gap where several RPC functions retained default public execute access; access is now correctly restricted to signed-in users only. **Existing installations should re-run `combined_schema.sql`** in the Supabase SQL Editor to pick up this fix (safe to re-run — fully idempotent).

### v1.1.98 (September 2026)
- Update: Terms of Service and FAQ pricing wording refreshed

### v1.1.97 (September 2026)
- Update: Plan & Billing page pricing display refreshed

### v1.1.96 (September 2026)
- Feature: client query links now show a 7-day expiry notice when shared with clients

### v1.1.95 (September 2026)
- Feature: quarterly and annual BAS workpaper merge, generated directly in the browser

### v1.1.94 (August 2026)
- Fix: database setup script can now be safely re-run on an existing installation

### v1.1.93 (August 2026)
- Fix: workflow pages now show a clear error message instead of failing silently
- Feature: new Setup Health Check page (owner/admin) to verify your installation is configured correctly
- Feature: in-app notice when a newer version is available

### v1.1.90 (August 2026)
- Enhancement: exported GST and BAS Summary workbooks now include full staff sign-off and client cover details, matching the cloud edition

### v1.1.85 (August 2026)
- Fix: new folders now correctly inherit the assigned team member, so junior staff can see their work
- **Existing installations**: run this once in the Supabase SQL Editor to repair older folders:
  ```sql
  UPDATE cases c SET assigned_junior = cl.assigned_junior
  FROM clients cl WHERE c.client_id = cl.id AND c.assigned_junior IS NULL;
  ```

### v1.1.84 (August 2026)
- Fix: staff can now see tasks assigned to them across folders created by other team members

### v1.1.83 (August 2026)
- Fix: workflow tasks are now assigned to the correct team member at every step

### v1.1.82 (August 2026)
- Fix: usage and billing pages remain accessible even when your MCP quota is used up
- Feature: clear warning shown when your MCP quota is running low or exhausted
- Fix: clearer error messages for API key issues

### v1.1.81 (August 2026)
- Fix: resolved a permissions error when logging workflow activity
- Fix: increased timeout for processing large PDF statements

### v1.1.80 (August 2026)
- Fix: improved reliability of activity logging

### v1.1.79 (August 2026)
- Fix: approval buttons now correctly reflect each user's permissions
- Fix: resolved a duplicate task issue after rejecting and resubmitting a workpaper

### v1.1.74 (August 2026)
- Security: strengthened access-control checks across the platform
- Fix: additional team roles can now manage directors and SLA profiles as intended

### v1.1.69 (August 2026)
- Fix: Owner role can now add team members
- Fix: resolved a flash of a false error message on the Manager Review page

### v1.1.60 (August 2026)
- Fix: approve/reject actions now correctly respect each role's permissions

### v1.1.54 (August 2026)
- Feature: Case Log now covers client query and document activity, with clearer filtering and step labels

### v1.1.43 (August 2026)
- Fix: workpaper files now appear reliably in the Working Paper Files panel after each workflow step

### v1.1.26 (August 2026)
- Fix: GST breakdown and tab counts on the Senior Review page now update live as you edit

### v1.1.18 (August 2026)
- Fix: resolved duplicate task entries that could appear in Folder Steps
- **Existing installations**: if you notice duplicate "Extract" entries, run this once in the Supabase SQL Editor:
  ```sql
  DELETE FROM tasks WHERE id IN (
    SELECT id FROM (
      SELECT id, ROW_NUMBER() OVER (PARTITION BY case_id ORDER BY completed_at DESC) AS rn
      FROM tasks WHERE task_type = 'extract'
    ) sub WHERE rn > 1
  );
  ```

### v1.1.17 (August 2026)
- Fix: resolved a connection error when calling the MCP extraction service

### v1.1.16 (August 2026)
- Fix: resolved an error when creating a new folder

### v1.1.15 (August 2026)
- Fix: MCP key now detected correctly on the Modules page

### v1.1.14 (August 2026)
- Fix: database setup script reliability improvements

### v1.1.04 (August 2026)
- Fix: client query file uploads and document downloads now work reliably
- Action required: re-run the latest database setup script in the Supabase SQL Editor, then confirm Storage buckets per the README setup steps

### v1.1.02 (August 2026)
- Feature: full Partner approval workflow (Manager Review → Client Confirm → Certify) now available in self-hosted mode

*For earlier versions (v1.0.x), see [GitHub Releases](https://github.com/sweeper-acct/self-hosted/releases).*
