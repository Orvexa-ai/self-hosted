-- Sweeper combined schema — generated 2026-10-21T00:29:16Z
-- Apply this file in Supabase SQL Editor (one paste, no CLI required)


-- ── 20260101000001_core_tables.sql ───────────────────────────────────
-- Migration 001 — Core tables: firms, teams, users, sla_profiles
-- No RLS in this migration — applied in Migration 004.
-- Enums, foreign keys, check constraints, indexes all included here.

-- ── firms ─────────────────────────────────────────────────────────────────────
-- gen_random_uuid() is built into PostgreSQL 13+ — no extension needed.

CREATE TABLE firms (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                TEXT NOT NULL,
    abn                 CHAR(11),                        -- 11 digits, no spaces
    address             TEXT,
    subscription_plan   TEXT NOT NULL DEFAULT 'starter'
                            CHECK (subscription_plan IN ('starter', 'professional', 'enterprise')),
    data_region         TEXT NOT NULL DEFAULT 'ap-southeast-2',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON COLUMN firms.abn IS '11-digit Australian Business Number, stored without spaces or hyphens';
COMMENT ON COLUMN firms.data_region IS 'Must be ap-southeast-2 (Sydney) for Australian data residency compliance';

-- ── sla_profiles ──────────────────────────────────────────────────────────────
-- Created before teams because teams will reference it in a later migration.
-- Defined here so the table exists when Migration 002 adds the FK on clients.

CREATE TABLE sla_profiles (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    firm_id         UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    -- SLA days per workflow step. Zero = same business day.
    -- Keys must match task_type values in tasks table (Migration 003).
    step_sla_days   JSONB NOT NULL DEFAULT '{
        "extract":              0,
        "validate_extraction":  1,
        "gst_prep":             0,
        "validate_gst":         1,
        "senior_review":        2,
        "bas_draft":            0,
        "manager_review":       1,
        "client_confirm":       2,
        "certify":              1
    }'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_sla_profiles_firm_id ON sla_profiles(firm_id);

-- ── teams ─────────────────────────────────────────────────────────────────────
-- approval_chain drives the Orchestrator's dynamic task plan.
-- The Orchestrator reads this at case creation to determine which optional
-- steps (senior_review, manager_approve) to include in the workflow.
-- Updated by the system whenever team members change roles.

CREATE TABLE teams (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    firm_id         UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
    -- partner_id resolved after users table exists; added via ALTER below.
    name            TEXT NOT NULL,
    approval_chain  JSONB NOT NULL DEFAULT '{
        "senior_review":    false,
        "senior_id":        null,
        "manager_approve":  false,
        "manager_id":       null
    }'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_teams_firm_id ON teams(firm_id);

-- ── users ─────────────────────────────────────────────────────────────────────
-- id matches Supabase Auth user UUID — no separate auth table needed.
-- role is stored here; JWT custom claims hook reads this to inject into token.

CREATE TABLE users (
    id          UUID PRIMARY KEY,           -- must match auth.users.id
    firm_id     UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
    team_id     UUID NOT NULL REFERENCES teams(id) ON DELETE RESTRICT,
    name        TEXT NOT NULL,
    email       TEXT NOT NULL,
    role        TEXT NOT NULL
                    CHECK (role IN ('admin', 'partner', 'manager', 'senior', 'junior')),
    status      TEXT NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'inactive', 'pending')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (firm_id, email)
);

CREATE INDEX idx_users_firm_id   ON users(firm_id);
CREATE INDEX idx_users_team_id   ON users(team_id);
CREATE INDEX idx_users_role      ON users(team_id, role);   -- common: "all juniors in team"

-- ── Back-fill FK: teams.partner_id → users ────────────────────────────────────
-- Added after users exists to avoid circular dependency.
-- Nullable because the team may be created before the partner user record exists
-- during onboarding (partner invites themselves first).

ALTER TABLE teams
    ADD COLUMN partner_id UUID REFERENCES users(id) ON DELETE SET NULL;

CREATE INDEX idx_teams_partner_id ON teams(partner_id);

-- ── Back-fill FK: sla_profiles default on teams ───────────────────────────────
-- Teams can have a default SLA profile. Added here after sla_profiles exists.
-- Clients can override per-client (added in Migration 002).

ALTER TABLE teams
    ADD COLUMN default_sla_profile_id UUID REFERENCES sla_profiles(id) ON DELETE SET NULL;

-- ── updated_at triggers ───────────────────────────────────────────────────────
-- Keeps updated_at current without relying on application layer.

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_firms_updated_at
    BEFORE UPDATE ON firms
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_teams_updated_at
    BEFORE UPDATE ON teams
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_sla_profiles_updated_at
    BEFORE UPDATE ON sla_profiles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ── approval_chain integrity check ───────────────────────────────────────────
-- Enforces: if senior_review=true then senior_id must not be null,
-- and vice versa. Same for manager_approve / manager_id.
-- Applied as a CHECK constraint using a plpgsql function so the logic
-- is readable and reusable.

CREATE OR REPLACE FUNCTION validate_approval_chain(chain JSONB)
RETURNS BOOLEAN AS $$
BEGIN
    -- senior_review enabled → senior_id must be present
    IF (chain->>'senior_review')::boolean IS TRUE
       AND (chain->>'senior_id') IS NULL THEN
        RETURN FALSE;
    END IF;
    -- senior_id present → senior_review must be enabled
    IF (chain->>'senior_id') IS NOT NULL
       AND (chain->>'senior_review')::boolean IS NOT TRUE THEN
        RETURN FALSE;
    END IF;
    -- manager_approve enabled → manager_id must be present
    IF (chain->>'manager_approve')::boolean IS TRUE
       AND (chain->>'manager_id') IS NULL THEN
        RETURN FALSE;
    END IF;
    -- manager_id present → manager_approve must be enabled
    IF (chain->>'manager_id') IS NOT NULL
       AND (chain->>'manager_approve')::boolean IS NOT TRUE THEN
        RETURN FALSE;
    END IF;
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Default value passes validation (all false/null), so existing rows are fine.
-- The constraint allows null senior_id/manager_id when corresponding flag is false.
ALTER TABLE teams
    ADD CONSTRAINT chk_approval_chain_consistency
    CHECK (validate_approval_chain(approval_chain));


-- ── 20260101000002_client_tables.sql ───────────────────────────────────
-- Migration 002 鈥?Client tables: coding_rule_sets, clients, directors
-- No RLS in this migration 鈥?applied in Migration 004.
--
-- Circular dependency between coding_rule_sets 鈫?clients is resolved by:
--   1. Create coding_rule_sets (firm_id only, no client_id yet)
--   2. Create clients (references coding_rule_sets)
--   3. ALTER coding_rule_sets to add client_id (references clients)

-- 鈹€鈹€ coding_rule_sets 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
-- firm_id + client_id = null  鈫?firm-level default (one per firm)
-- firm_id + client_id = uuid  鈫?client-specific override (one per client)
--
-- GST coding rule priority (enforced by BASAgent, not here):
--   Priority 1 鈥?custom rules from this table (mode = 'custom')
--   Priority 2 鈥?standard ATO rules (BASAgent built-in)
--   Priority 3 鈥?LLM + Orvexa signal (last resort, always flagged)

CREATE TABLE coding_rule_sets (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    firm_id         UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
    -- client_id added after clients table exists (see ALTER below)
    name            TEXT NOT NULL,
    mode            TEXT NOT NULL DEFAULT 'standard'
                        CHECK (mode IN ('standard', 'custom')),
    -- Array of rule objects. Each rule:
    --   { "field": "supplier"|"amount"|"description",
    --     "operator": "contains"|"equals"|"lt"|"gt"|"lte"|"gte",
    --     "value": <string or number>,
    --     "gst_code": "G1"|"G2"|"G3"|"G4"|"G10"|"G11"|"G20",
    --     "type": "cash"|"accruals"  (optional, for amount rules) }
    custom_rules    JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- When mode='standard', custom_rules must be empty (they are ignored by
    -- BASAgent but an inconsistent state here would be confusing in audits).
    CONSTRAINT chk_coding_rules_mode_consistency
        CHECK (
            (mode = 'standard' AND custom_rules = '[]'::jsonb)
            OR mode = 'custom'
        ),

    -- custom_rules must always be a JSON array, never an object or scalar.
    CONSTRAINT chk_coding_rules_is_array
        CHECK (jsonb_typeof(custom_rules) = 'array')
);

CREATE INDEX idx_coding_rule_sets_firm_id ON coding_rule_sets(firm_id);

-- 鈹€鈹€ clients 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
-- firm_id is denormalised from teams for RLS performance.
-- Set automatically by trigger on INSERT 鈥?application must not pass it.
--
-- assigned_junior: one Junior per client (fixed assignment).
-- Required when status = 'active'; nullable during onboarding (status = 'pending').

CREATE TABLE clients (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    firm_id                 UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
    team_id                 UUID NOT NULL REFERENCES teams(id) ON DELETE RESTRICT,
    business_name           TEXT NOT NULL,
    abn                     CHAR(11),
    entity_type             TEXT NOT NULL
                                CHECK (entity_type IN (
                                    'company', 'trust', 'partnership',
                                    'sole_trader', 'individual', 'smsf', 'other'
                                )),
    industry                TEXT,
    address                 TEXT,
    bas_cycle               TEXT NOT NULL DEFAULT 'quarterly'
                                CHECK (bas_cycle IN ('monthly', 'quarterly', 'annual')),
    gst_method              TEXT NOT NULL DEFAULT 'accruals'
                                CHECK (gst_method IN ('cash', 'accruals')),
    status                  TEXT NOT NULL DEFAULT 'pending'
                                CHECK (status IN ('pending', 'active', 'inactive')),
    assigned_junior         UUID REFERENCES users(id) ON DELETE SET NULL,
    coding_rule_set_id      UUID REFERENCES coding_rule_sets(id) ON DELETE SET NULL,
    sla_profile_id          UUID REFERENCES sla_profiles(id) ON DELETE SET NULL,
    activated_at            TIMESTAMPTZ,
    created_by              UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Active clients must have an assigned Junior.
    -- Inactive clients retain their last assigned_junior for audit trail.
    CONSTRAINT chk_active_client_has_junior
        CHECK (status != 'active' OR assigned_junior IS NOT NULL),

    -- activated_at must be set when (and only when) status becomes 'active'.
    CONSTRAINT chk_activated_at_consistency
        CHECK (
            (status = 'active' AND activated_at IS NOT NULL)
            OR (status != 'active' AND activated_at IS NULL)
        )
);

-- Indexes from checklist requirement: "composite indexes on (team_id, status)
-- and (assigned_junior, status)"
CREATE INDEX idx_clients_team_status       ON clients(team_id, status);
CREATE INDEX idx_clients_junior_status     ON clients(assigned_junior, status);
CREATE INDEX idx_clients_firm_id           ON clients(firm_id);
CREATE INDEX idx_clients_coding_rule_set   ON clients(coding_rule_set_id);

-- 鈹€鈹€ firm_id auto-population trigger for clients 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
-- Ensures firm_id on clients always matches teams.firm_id.
-- Application never passes firm_id for client INSERT 鈥?trigger sets it.
-- On UPDATE of team_id (team reassignment), firm_id is recalculated.

CREATE OR REPLACE FUNCTION set_client_firm_id()
RETURNS TRIGGER AS $$
BEGIN
    SELECT firm_id INTO NEW.firm_id
    FROM teams
    WHERE id = NEW.team_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'team_id % does not exist', NEW.team_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_clients_set_firm_id
    BEFORE INSERT OR UPDATE OF team_id ON clients
    FOR EACH ROW EXECUTE FUNCTION set_client_firm_id();

-- 鈹€鈹€ Back-fill: coding_rule_sets.client_id 鈫?clients 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
-- Added now that clients exists. Nullable: null = firm-level default rule set.

ALTER TABLE coding_rule_sets
    ADD COLUMN client_id UUID REFERENCES clients(id) ON DELETE CASCADE;

CREATE INDEX idx_coding_rule_sets_client_id ON coding_rule_sets(client_id);

-- One rule set per (firm, client) pair. client_id = null means firm default,
-- and there can be only one firm default per firm.
CREATE UNIQUE INDEX idx_coding_rule_sets_firm_client
    ON coding_rule_sets(firm_id, client_id);
-- Note: UNIQUE INDEX on (firm_id, client_id) where client_id IS NULL is valid
-- in Postgres 鈥?NULLs are treated as distinct by default, but for a unique
-- partial index covering the null case we use:
CREATE UNIQUE INDEX idx_coding_rule_sets_firm_default
    ON coding_rule_sets(firm_id)
    WHERE client_id IS NULL;

-- Drop the less-specific index now that the partial unique index covers nulls.
DROP INDEX idx_coding_rule_sets_firm_client;

-- 鈹€鈹€ directors 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
-- Multiple directors per client. Used for client confirmation step (BAS sign-off).

CREATE TABLE directors (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id   UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    position    TEXT,
    email       TEXT,
    phone       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_directors_client_id ON directors(client_id);

-- 鈹€鈹€ updated_at triggers 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

CREATE TRIGGER trg_coding_rule_sets_updated_at
    BEFORE UPDATE ON coding_rule_sets
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_clients_updated_at
    BEFORE UPDATE ON clients
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_directors_updated_at
    BEFORE UPDATE ON directors
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ── 20260101000003_case_tables.sql ───────────────────────────────────
-- Migration 003 鈥?Case tables: cases, files, tasks, task_edits, case_log
-- Covers 003a (case_type values) in the same file 鈥?TEXT + CHECK, not Postgres ENUM.
-- No RLS in this migration 鈥?applied in Migration 004.
--
-- Append-only enforcement:
--   case_log  鈫?BEFORE DELETE/UPDATE FOR EACH STATEMENT 鈫?RAISE EXCEPTION (service role included)
--   files     鈫?BEFORE UPDATE FOR EACH ROW 鈫?RAISE EXCEPTION if file_state changes
--              (INSERT-only model: each state transition = new file record, never update-in-place)
--
-- Denormalised fields (set by trigger, application must not pass them):
--   cases.firm_id    鈫?clients.firm_id
--   cases.team_id    鈫?clients.team_id   (enforces case always follows client's team)
--   files.firm_id    鈫?cases.firm_id
--   tasks.firm_id    鈫?cases.firm_id
--   tasks.case_type  鈫?cases.case_type   (sync: update both CHECK lists together)

-- 鈹€鈹€ case_type canonical list (003a) 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
-- Defined once as a SQL function so both cases.case_type and tasks.case_type
-- reference the same truth 鈥?if a new business line is added, update this
-- function AND the two CHECK constraints below.
--
-- MVP active:    bank_statement, bas_gst
-- Reserved only: all others 鈥?UI shows "Coming soon", workflow cannot start

CREATE OR REPLACE FUNCTION is_mvp_active_case_type(ct TEXT) RETURNS BOOLEAN AS $$
BEGIN
    RETURN ct IN ('bank_statement', 'bas_gst');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 鈹€鈹€ cases 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€

CREATE TABLE cases (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id       UUID NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
    -- team_id and firm_id are derived from client_id by trigger on INSERT/UPDATE.
    -- Application must not pass these 鈥?they are set automatically.
    team_id         UUID NOT NULL REFERENCES teams(id) ON DELETE RESTRICT,
    firm_id         UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
    case_type       TEXT NOT NULL
                        CHECK (case_type IN (
                            -- MVP active
                            'bank_statement', 'bas_gst',
                            -- Reserved 鈥?not implemented in MVP.
                            -- Add future business lines here AND in tasks.case_type CHECK.
                            'tax_return', 'payroll', 'smsf',
                            'asic', 'audit', 'advisory'
                        )),
    -- Computed convenience flag. Application reads this to gate workflow start.
    -- True only for MVP-active types; reserved types are always false.
    is_mvp_active   BOOLEAN NOT NULL
                        GENERATED ALWAYS AS (
                            case_type IN ('bank_statement', 'bas_gst')
                        ) STORED,
    period          TEXT NOT NULL
                        CHECK (period ~ '^\d{4}-(0[1-9]|1[0-2])$'),
    status          TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN (
                            'pending',        -- created, no tasks started
                            'in_progress',    -- at least one task running
                            'waiting_human',  -- paused at a human gate
                            'complete',       -- Partner certified
                            'cancelled'
                        )),
    current_step    TEXT,    -- mirrors the active task's task_type; null before first task
    assigned_junior UUID REFERENCES users(id) ON DELETE SET NULL,
    assigned_senior UUID REFERENCES users(id) ON DELETE SET NULL,
    sla_profile_id  UUID REFERENCES sla_profiles(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_cases_team_status     ON cases(team_id, status);
CREATE INDEX idx_cases_client_id       ON cases(client_id);
CREATE INDEX idx_cases_firm_id         ON cases(firm_id);
CREATE INDEX idx_cases_assigned_junior ON cases(assigned_junior);
CREATE INDEX idx_cases_assigned_senior ON cases(assigned_senior);
CREATE INDEX idx_cases_case_type       ON cases(case_type, team_id);
CREATE INDEX idx_cases_period          ON cases(period);

-- Derive team_id and firm_id from client_id. Fires on INSERT and when client_id
-- changes (client reassignment propagates to the case automatically).
CREATE OR REPLACE FUNCTION set_case_derived_fields()
RETURNS TRIGGER AS $$
BEGIN
    SELECT firm_id, team_id
    INTO   NEW.firm_id, NEW.team_id
    FROM   clients
    WHERE  id = NEW.client_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'client_id % does not exist', NEW.client_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_cases_set_derived_fields
    BEFORE INSERT OR UPDATE OF client_id ON cases
    FOR EACH ROW EXECUTE FUNCTION set_case_derived_fields();

CREATE TRIGGER trg_cases_updated_at
    BEFORE UPDATE ON cases
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 鈹€鈹€ files 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
-- INSERT-only: each workflow state transition creates a NEW file record.
-- file_state is set at INSERT and must never be changed.
-- storage_path must be prefixed with firm_id to prevent cross-tenant access.
--
-- State sequence (forward only, never reversed):
--   raw 鈫?extracted 鈫?validated 鈫?processed 鈫?reviewed 鈫?final 鈫?archived
--   鈽?validated and reviewed are human-certified (written only by system on human action)
--   鈽?archived is immutable 鈥?Partner certify locks the file permanently

CREATE TABLE files (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id         UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    firm_id         UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
    file_name       TEXT NOT NULL,
    file_type       TEXT NOT NULL
                        CHECK (file_type IN ('pdf', 'xlsx', 'xls', 'csv')),
    storage_path    TEXT NOT NULL,
    file_state      TEXT NOT NULL
                        CHECK (file_state IN (
                            'raw', 'extracted', 'validated',
                            'processed', 'reviewed', 'final', 'archived'
                        )),
    source          TEXT NOT NULL
                        CHECK (source IN (
                            'uploaded',          -- user upload
                            'agent_generated',   -- BookkeepingAgent or BASAgent output
                            'human_certified'    -- promoted by system on human submit/approve
                        )),
    uploaded_by     UUID REFERENCES users(id) ON DELETE SET NULL,
    uploaded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- No updated_at: files are INSERT-only, no field should be tracked for change time.

    -- Storage path must be scoped to the owning firm. Prevents cross-tenant path construction.
    CONSTRAINT chk_storage_path_firm_scoped
        CHECK (storage_path LIKE (firm_id::text || '/%'))
);

CREATE INDEX idx_files_case_state  ON files(case_id, file_state);
CREATE INDEX idx_files_firm_id     ON files(firm_id);
CREATE INDEX idx_files_uploaded_by ON files(uploaded_by);

-- Derive firm_id from the parent case. Fires on INSERT only (case_id never changes).
CREATE OR REPLACE FUNCTION set_file_firm_id()
RETURNS TRIGGER AS $$
BEGIN
    SELECT firm_id INTO NEW.firm_id
    FROM   cases
    WHERE  id = NEW.case_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'case_id % does not exist', NEW.case_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_files_set_firm_id
    BEFORE INSERT ON files
    FOR EACH ROW EXECUTE FUNCTION set_file_firm_id();

-- Prevent file_state from ever being changed after INSERT.
-- Other columns (file_name, storage_path) may be updated 鈥?only file_state is locked.
CREATE OR REPLACE FUNCTION prevent_file_state_update()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.file_state IS DISTINCT FROM OLD.file_state THEN
        RAISE EXCEPTION
            'file_state is immutable after INSERT. '
            'Transition attempted: % 鈫?%. '
            'Create a new file record instead.',
            OLD.file_state, NEW.file_state;
    END IF;
    RETURN NEW;  -- allow update to proceed (for other columns)
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_files_immutable_state
    BEFORE UPDATE ON files
    FOR EACH ROW EXECUTE FUNCTION prevent_file_state_update();

-- 鈹€鈹€ tasks 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
-- One task per workflow step per case. Orchestrator creates tasks;
-- humans and agents update status.
--
-- case_type is denormalised from cases for JOIN-free filtering.
-- Must use the same CHECK list as cases.case_type 鈥?update both together
-- when adding new business lines.
--
-- task_type covers BAS/GST workflow steps (MVP). Future business lines
-- will add their own step names here. The case_type column identifies
-- which business line a task belongs to, enabling type-safe routing.

CREATE TABLE tasks (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id         UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    firm_id         UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
    -- Sync note: update this CHECK and cases.case_type CHECK together.
    case_type       TEXT NOT NULL
                        CHECK (case_type IN (
                            'bank_statement', 'bas_gst',
                            'tax_return', 'payroll', 'smsf',
                            'asic', 'audit', 'advisory'
                        )),
    task_type       TEXT NOT NULL
                        CHECK (task_type IN (
                            -- BAS/GST workflow steps (MVP active)
                            'extract',
                            'validate_extraction',
                            'gst_prep',
                            'validate_gst',
                            'senior_review',
                            'bas_draft',
                            'manager_review',
                            'client_confirm',
                            'certify'
                            -- Add future business line step names here as implemented.
                            -- Pattern: keep step names generic where possible so they
                            -- can be reused across business lines (e.g. senior_review,
                            -- client_confirm, certify are business-line agnostic).
                        )),
    assigned_agent  TEXT
                        CHECK (assigned_agent IN (
                            -- MVP active
                            'bookkeeping_agent', 'bas_agent', 'human',
                            -- Reserved for future phases
                            'tax_agent', 'payroll_agent', 'smsf_agent',
                            'asic_agent', 'audit_agent', 'advisory_agent'
                        )),
    assigned_to     UUID REFERENCES users(id) ON DELETE SET NULL,
    status          TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN (
                            'pending',
                            'in_progress',
                            'waiting_human',
                            'approved',
                            'rejected',
                            'complete'
                        )),
    sla_due_at      TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ,
    reject_comment  TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Human-assigned tasks must have a specific user assigned.
    CONSTRAINT chk_human_task_has_assignee
        CHECK (assigned_agent != 'human' OR assigned_to IS NOT NULL),

    -- completed_at must only be set when status is terminal.
    CONSTRAINT chk_completed_at_consistency
        CHECK (
            (status IN ('approved', 'rejected', 'complete') AND completed_at IS NOT NULL)
            OR status NOT IN ('approved', 'rejected', 'complete')
        )
);

CREATE INDEX idx_tasks_case_id        ON tasks(case_id);
CREATE INDEX idx_tasks_assigned_to    ON tasks(assigned_to, status);
CREATE INDEX idx_tasks_firm_status    ON tasks(firm_id, status);
CREATE INDEX idx_tasks_case_type      ON tasks(case_type, firm_id);

-- Derive firm_id and case_type from parent case on INSERT.
-- case_id never changes after insert, so UPDATE trigger not needed.
CREATE OR REPLACE FUNCTION set_task_derived_fields()
RETURNS TRIGGER AS $$
BEGIN
    SELECT firm_id, case_type
    INTO   NEW.firm_id, NEW.case_type
    FROM   cases
    WHERE  id = NEW.case_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'case_id % does not exist', NEW.case_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_tasks_set_derived_fields
    BEFORE INSERT ON tasks
    FOR EACH ROW EXECUTE FUNCTION set_task_derived_fields();

CREATE TRIGGER trg_tasks_updated_at
    BEFORE UPDATE ON tasks
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 鈹€鈹€ task_edits 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
-- Immutable audit trail of inline edits made by humans during validate/review steps.
-- row_ref identifies which row in the task output was edited (e.g. transaction ID).

CREATE TABLE task_edits (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id     UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    row_ref     TEXT NOT NULL,
    field       TEXT NOT NULL,
    old_value   TEXT,
    new_value   TEXT,
    edited_by   UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    edited_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
    -- No updated_at: task_edits are INSERT-only by convention (not DB-enforced here;
    -- enforcement comes via no UPDATE endpoint in the API layer + RLS in Migration 004).
);

CREATE INDEX idx_task_edits_task_id ON task_edits(task_id);
CREATE INDEX idx_task_edits_edited_by ON task_edits(edited_by);

-- 鈹€鈹€ case_log 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
-- Immutable audit log. Every routing decision, human action, and agent output is
-- recorded here. Retention: 5 years minimum (compliance requirement).
--
-- Append-only enforcement: BEFORE DELETE/UPDATE FOR EACH STATEMENT triggers
-- raise exceptions for ALL callers 鈥?including service role (which bypasses RLS
-- but not triggers). This is the structural guarantee; RLS in Migration 004
-- adds defence-in-depth for normal user paths.
--
-- diagnostic_observation entries: output_snapshot must contain
--   { "speculative": true, "language": "may indicate / possible / unverified" }
-- This is an application-layer convention 鈥?not DB-enforced to keep the schema
-- flexible for future observation types.

CREATE TABLE case_log (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id         UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    actor_type      TEXT NOT NULL
                        CHECK (actor_type IN (
                            'human',
                            'hermes_orchestrator',
                            'bookkeeping_agent',
                            'bas_agent'
                            -- Add future agent types here as implemented.
                        )),
    -- Null for agent actors; required for human actors (see constraints below).
    actor_id        UUID REFERENCES users(id) ON DELETE SET NULL,
    action          TEXT NOT NULL
                        CHECK (action IN (
                            -- Orchestrator routing decisions
                            'delegate', 'promote', 'pause', 'resume', 'reject_route',
                            -- Human actions
                            'validate', 'approve', 'reject', 'certify',
                            -- Agent completion signals
                            'extraction_complete', 'gst_prep_complete', 'bas_draft_complete',
                            -- Orchestrator diagnostic (speculative, never triggers behaviour)
                            'diagnostic_observation'
                        )),
    input_snapshot  JSONB,
    output_snapshot JSONB,
    logged_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Human actions must be traceable to a user.
    CONSTRAINT chk_case_log_human_has_actor
        CHECK (actor_type != 'human' OR actor_id IS NOT NULL),

    -- Agent entries must not carry a user actor_id (no impersonation).
    CONSTRAINT chk_case_log_agent_no_actor
        CHECK (actor_type = 'human' OR actor_id IS NULL)
);

-- Primary audit query pattern: all events for a case in chronological order.
CREATE INDEX idx_case_log_case_time   ON case_log(case_id, logged_at);
CREATE INDEX idx_case_log_actor_id    ON case_log(actor_id) WHERE actor_id IS NOT NULL;
CREATE INDEX idx_case_log_action      ON case_log(action, logged_at);

-- 鈹€鈹€ case_log append-only triggers 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€
-- FOR EACH STATEMENT fires before RLS evaluation, catching all callers including
-- service role. RETURN NULL after RAISE EXCEPTION is unreachable but satisfies
-- plpgsql static analysis (avoids schema linter warnings).

CREATE OR REPLACE FUNCTION prevent_case_log_mutation()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION
        'case_log is append-only. % is not permitted. '
        'Retention policy: 5 years minimum (compliance requirement).',
        TG_OP;
    RETURN NULL;  -- never reached; satisfies plpgsql static analysis
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_case_log_no_delete
    BEFORE DELETE ON case_log
    FOR EACH STATEMENT
    EXECUTE FUNCTION prevent_case_log_mutation();

CREATE TRIGGER trg_case_log_no_update
    BEFORE UPDATE ON case_log
    FOR EACH STATEMENT
    EXECUTE FUNCTION prevent_case_log_mutation();


-- ── 20260101000004_rls_policies.sql ───────────────────────────────────
-- Migration 004 — Row Level Security policies
--
-- Architecture: RESTRICTIVE firm boundary + PERMISSIVE role branches
--   RESTRICTIVE (firm_id = auth_firm_id()): outer fence, always enforced.
--     A bug in any PERMISSIVE policy cannot cause cross-firm data leak.
--   PERMISSIVE (role branches): inner access logic, OR-combined per operation.
--     Any single PERMISSIVE policy passing is sufficient for access.
--
-- Write policies (INSERT/UPDATE): loose version — team member can write to own
--   team's records. Phase 2 tightens to field-level and role-level constraints.
--
-- DELETE policies: intentionally absent on all tables.
--   No DELETE = default deny. Sweeper uses status transitions, not hard deletes.
--   Exceptions enforced by trigger (case_log, file_state) are in Migration 003.
--
-- JWT claim extraction: always use the three helper functions below.
--   NEVER use auth.role() or current_role for app-level role checks —
--   auth.role() returns our app role (junior/senior/...) but only because our
--   custom JWT hook overwrites the standard 'role' claim. current_role returns
--   the Postgres database role ('authenticated'), which is NEVER the right
--   variable for app-level role checks in RLS. See CLAUDE.md JWT section.

-- ── Helper functions ──────────────────────────────────────────────────────────
-- STABLE: result is consistent within a single query; JWT doesn't change per request.
-- Centralised here — if Supabase changes claim injection path, change only these.

CREATE OR REPLACE FUNCTION auth_firm_id() RETURNS UUID AS $$
    SELECT (auth.jwt() ->> 'firm_id')::uuid
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION auth_team_id() RETURNS UUID AS $$
    SELECT (auth.jwt() ->> 'team_id')::uuid
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION auth_user_role() RETURNS TEXT AS $$
    SELECT auth.jwt() ->> 'role'
$$ LANGUAGE sql STABLE;

-- ── Enable RLS on all tables ──────────────────────────────────────────────────

ALTER TABLE firms             ENABLE ROW LEVEL SECURITY;
ALTER TABLE sla_profiles      ENABLE ROW LEVEL SECURITY;
ALTER TABLE teams             ENABLE ROW LEVEL SECURITY;
ALTER TABLE users             ENABLE ROW LEVEL SECURITY;
ALTER TABLE coding_rule_sets  ENABLE ROW LEVEL SECURITY;
ALTER TABLE clients           ENABLE ROW LEVEL SECURITY;
ALTER TABLE directors         ENABLE ROW LEVEL SECURITY;
ALTER TABLE cases             ENABLE ROW LEVEL SECURITY;
ALTER TABLE files             ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasks             ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_edits        ENABLE ROW LEVEL SECURITY;
ALTER TABLE case_log          ENABLE ROW LEVEL SECURITY;

-- ════════════════════════════════════════════════════════════════════════════
-- firms
-- Firm table's own id IS the firm_id. RESTRICTIVE uses id = auth_firm_id().
-- All roles see their own firm. Admin-only writes (firm creation is
-- platform-level onboarding, not user-initiated).
-- ════════════════════════════════════════════════════════════════════════════

CREATE POLICY firms_firm_boundary ON firms
    AS RESTRICTIVE FOR ALL
    USING     (id = auth_firm_id())
    WITH CHECK(id = auth_firm_id());

CREATE POLICY firms_select ON firms
    AS PERMISSIVE FOR SELECT
    USING (true);
    -- firm_boundary restricts to own firm; no further role branching needed.

CREATE POLICY firms_insert ON firms
    AS PERMISSIVE FOR INSERT
    WITH CHECK (auth_user_role() = 'admin');

CREATE POLICY firms_update ON firms
    AS PERMISSIVE FOR UPDATE
    USING     (auth_user_role() = 'admin')
    WITH CHECK(auth_user_role() = 'admin');

-- ════════════════════════════════════════════════════════════════════════════
-- sla_profiles
-- Firm-level configuration; all roles can read (SLA deadlines are visible
-- across the team). Admin/Partner/Manager can write.
-- ════════════════════════════════════════════════════════════════════════════

CREATE POLICY sla_profiles_firm_boundary ON sla_profiles
    AS RESTRICTIVE FOR ALL
    USING     (firm_id = auth_firm_id())
    WITH CHECK(firm_id = auth_firm_id());

CREATE POLICY sla_profiles_select ON sla_profiles
    AS PERMISSIVE FOR SELECT
    USING (true);

CREATE POLICY sla_profiles_insert ON sla_profiles
    AS PERMISSIVE FOR INSERT
    WITH CHECK (auth_user_role() IN ('admin', 'partner', 'manager'));

CREATE POLICY sla_profiles_update ON sla_profiles
    AS PERMISSIVE FOR UPDATE
    USING     (auth_user_role() IN ('admin', 'partner', 'manager'))
    WITH CHECK(auth_user_role() IN ('admin', 'partner', 'manager'));

-- ════════════════════════════════════════════════════════════════════════════
-- teams
-- Admin sees all teams in firm. Others see only their own team.
-- Writes: admin can manage all teams; partner/manager can update their own team
-- (approval_chain config, team settings). Phase 2 narrows to specific columns.
-- ════════════════════════════════════════════════════════════════════════════

CREATE POLICY teams_firm_boundary ON teams
    AS RESTRICTIVE FOR ALL
    USING     (firm_id = auth_firm_id())
    WITH CHECK(firm_id = auth_firm_id());

CREATE POLICY teams_select_admin ON teams
    AS PERMISSIVE FOR SELECT
    USING (auth_user_role() = 'admin');

CREATE POLICY teams_select_own ON teams
    AS PERMISSIVE FOR SELECT
    USING (id = auth_team_id());

CREATE POLICY teams_insert ON teams
    AS PERMISSIVE FOR INSERT
    WITH CHECK (auth_user_role() = 'admin');

CREATE POLICY teams_update ON teams
    AS PERMISSIVE FOR UPDATE
    USING (
        auth_user_role() = 'admin'
        OR (id = auth_team_id() AND auth_user_role() IN ('partner', 'manager'))
    )
    WITH CHECK(
        auth_user_role() = 'admin'
        OR (id = auth_team_id() AND auth_user_role() IN ('partner', 'manager'))
    );

-- ════════════════════════════════════════════════════════════════════════════
-- users
-- Admin sees all users in firm. Others see only own team.
-- Users can update their own record; admin can update any in firm;
-- partner/manager can update team members (role changes etc).
-- ════════════════════════════════════════════════════════════════════════════

CREATE POLICY users_firm_boundary ON users
    AS RESTRICTIVE FOR ALL
    USING     (firm_id = auth_firm_id())
    WITH CHECK(firm_id = auth_firm_id());

CREATE POLICY users_select_admin ON users
    AS PERMISSIVE FOR SELECT
    USING (auth_user_role() = 'admin');

CREATE POLICY users_select_team ON users
    AS PERMISSIVE FOR SELECT
    USING (team_id = auth_team_id());

-- INSERT: admin creates users (invite flow). Team join handled by auth hook.
CREATE POLICY users_insert ON users
    AS PERMISSIVE FOR INSERT
    WITH CHECK (auth_user_role() = 'admin');

CREATE POLICY users_update ON users
    AS PERMISSIVE FOR UPDATE
    USING (
        id = auth.uid()                                                -- own record
        OR auth_user_role() = 'admin'                                  -- admin: firm-wide
        OR (team_id = auth_team_id()
            AND auth_user_role() IN ('partner', 'manager'))            -- team lead
    )
    WITH CHECK(
        id = auth.uid()
        OR auth_user_role() = 'admin'
        OR (team_id = auth_team_id()
            AND auth_user_role() IN ('partner', 'manager'))
    );

-- ════════════════════════════════════════════════════════════════════════════
-- coding_rule_sets
-- Senior+ can read firm's rule sets (needed for GST coding context).
-- Manager+ can write. Junior cannot read — they don't need config access.
-- client_id = null means firm default; client_id = uuid means client override.
-- Both are accessible to the same roles (firm-level access, not team-scoped).
-- ════════════════════════════════════════════════════════════════════════════

CREATE POLICY coding_rule_sets_firm_boundary ON coding_rule_sets
    AS RESTRICTIVE FOR ALL
    USING     (firm_id = auth_firm_id())
    WITH CHECK(firm_id = auth_firm_id());

CREATE POLICY coding_rule_sets_select ON coding_rule_sets
    AS PERMISSIVE FOR SELECT
    USING (auth_user_role() IN ('admin', 'partner', 'manager', 'senior'));

CREATE POLICY coding_rule_sets_insert ON coding_rule_sets
    AS PERMISSIVE FOR INSERT
    WITH CHECK (auth_user_role() IN ('admin', 'partner', 'manager'));

CREATE POLICY coding_rule_sets_update ON coding_rule_sets
    AS PERMISSIVE FOR UPDATE
    USING     (auth_user_role() IN ('admin', 'partner', 'manager'))
    WITH CHECK(auth_user_role() IN ('admin', 'partner', 'manager'));

-- ════════════════════════════════════════════════════════════════════════════
-- clients
-- Three-tier SELECT:
--   admin        → all clients in firm (firm_boundary handles scoping)
--   partner/manager/senior → all clients in their team
--   junior       → only clients where assigned_junior = auth.uid()
--
-- INSERT/UPDATE: loose (team member) — Phase 2 adds field-level constraints,
-- e.g. assigned_junior can only be written by Senior+.
-- ════════════════════════════════════════════════════════════════════════════

CREATE POLICY clients_firm_boundary ON clients
    AS RESTRICTIVE FOR ALL
    USING     (firm_id = auth_firm_id())
    WITH CHECK(firm_id = auth_firm_id());

CREATE POLICY clients_select_admin ON clients
    AS PERMISSIVE FOR SELECT
    USING (auth_user_role() = 'admin');

CREATE POLICY clients_select_team ON clients
    AS PERMISSIVE FOR SELECT
    USING (
        team_id = auth_team_id()
        AND auth_user_role() IN ('partner', 'manager', 'senior')
    );

CREATE POLICY clients_select_junior ON clients
    AS PERMISSIVE FOR SELECT
    USING (
        assigned_junior = auth.uid()
        AND auth_user_role() = 'junior'
    );
    -- Junior only sees their assigned clients. team_id check is implicit:
    -- a junior's auth.uid() can only appear as assigned_junior within their firm
    -- (enforced by firm_boundary RESTRICTIVE + users.team_id).

CREATE POLICY clients_insert ON clients
    AS PERMISSIVE FOR INSERT
    WITH CHECK (team_id = auth_team_id());

CREATE POLICY clients_update ON clients
    AS PERMISSIVE FOR UPDATE
    USING     (team_id = auth_team_id())
    WITH CHECK(team_id = auth_team_id());

-- ════════════════════════════════════════════════════════════════════════════
-- directors
-- No direct firm_id or team_id — access is inherited from parent client.
-- RESTRICTIVE: EXISTS into clients (firm boundary).
-- SELECT: mirrors clients access pattern via EXISTS.
-- ════════════════════════════════════════════════════════════════════════════

CREATE POLICY directors_firm_boundary ON directors
    AS RESTRICTIVE FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM clients c
            WHERE c.id = directors.client_id
            AND c.firm_id = auth_firm_id()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM clients c
            WHERE c.id = directors.client_id
            AND c.firm_id = auth_firm_id()
        )
    );

CREATE POLICY directors_select_admin ON directors
    AS PERMISSIVE FOR SELECT
    USING (auth_user_role() = 'admin');

CREATE POLICY directors_select_team ON directors
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() IN ('partner', 'manager', 'senior')
        AND EXISTS (
            SELECT 1 FROM clients c
            WHERE c.id = directors.client_id
            AND c.team_id = auth_team_id()
        )
    );

CREATE POLICY directors_select_junior ON directors
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() = 'junior'
        AND EXISTS (
            SELECT 1 FROM clients c
            WHERE c.id = directors.client_id
            AND c.assigned_junior = auth.uid()
        )
    );

CREATE POLICY directors_insert ON directors
    AS PERMISSIVE FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM clients c
            WHERE c.id = directors.client_id
            AND c.team_id = auth_team_id()
        )
    );

CREATE POLICY directors_update ON directors
    AS PERMISSIVE FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM clients c
            WHERE c.id = directors.client_id
            AND c.team_id = auth_team_id()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM clients c
            WHERE c.id = directors.client_id
            AND c.team_id = auth_team_id()
        )
    );

-- ════════════════════════════════════════════════════════════════════════════
-- cases
-- Same three-tier SELECT as clients (admin / team / junior-assigned).
-- Junior access uses assigned_junior column (matches clients pattern).
-- ════════════════════════════════════════════════════════════════════════════

CREATE POLICY cases_firm_boundary ON cases
    AS RESTRICTIVE FOR ALL
    USING     (firm_id = auth_firm_id())
    WITH CHECK(firm_id = auth_firm_id());

CREATE POLICY cases_select_admin ON cases
    AS PERMISSIVE FOR SELECT
    USING (auth_user_role() = 'admin');

CREATE POLICY cases_select_team ON cases
    AS PERMISSIVE FOR SELECT
    USING (
        team_id = auth_team_id()
        AND auth_user_role() IN ('partner', 'manager', 'senior')
    );

CREATE POLICY cases_select_junior ON cases
    AS PERMISSIVE FOR SELECT
    USING (
        assigned_junior = auth.uid()
        AND auth_user_role() = 'junior'
    );

CREATE POLICY cases_insert ON cases
    AS PERMISSIVE FOR INSERT
    WITH CHECK (team_id = auth_team_id());
    -- firm_id and team_id are set by trigger from client_id —
    -- the WITH CHECK runs after the trigger, so the derived values are correct.

CREATE POLICY cases_update ON cases
    AS PERMISSIVE FOR UPDATE
    USING     (team_id = auth_team_id())
    WITH CHECK(team_id = auth_team_id());

-- ════════════════════════════════════════════════════════════════════════════
-- files
-- Has firm_id (denormalised by trigger) but not team_id.
-- RESTRICTIVE: firm_id boundary (same pattern as cases).
-- SELECT: admin by firm; others via parent case team membership.
-- Junior access: parent case must be assigned to them.
-- ════════════════════════════════════════════════════════════════════════════

CREATE POLICY files_firm_boundary ON files
    AS RESTRICTIVE FOR ALL
    USING     (firm_id = auth_firm_id())
    WITH CHECK(firm_id = auth_firm_id());

CREATE POLICY files_select_admin ON files
    AS PERMISSIVE FOR SELECT
    USING (auth_user_role() = 'admin');

CREATE POLICY files_select_team ON files
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() IN ('partner', 'manager', 'senior')
        AND EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = files.case_id
            AND c.team_id = auth_team_id()
        )
    );

CREATE POLICY files_select_junior ON files
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() = 'junior'
        AND EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = files.case_id
            AND c.assigned_junior = auth.uid()
        )
    );

CREATE POLICY files_insert ON files
    AS PERMISSIVE FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = files.case_id
            AND c.team_id = auth_team_id()
        )
    );
    -- file_state is INSERT-only; prevent_file_state_update trigger (Migration 003)
    -- blocks any UPDATE to the file_state column. No UPDATE policy needed for
    -- state transitions — they are handled by inserting new file records.

CREATE POLICY files_update ON files
    AS PERMISSIVE FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = files.case_id
            AND c.team_id = auth_team_id()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = files.case_id
            AND c.team_id = auth_team_id()
        )
    );

-- ════════════════════════════════════════════════════════════════════════════
-- tasks
-- Has firm_id and case_type (denormalised) but not team_id.
-- Junior can see all tasks for cases assigned to them — not just their own
-- task assignments — so they can track case progress.
-- ════════════════════════════════════════════════════════════════════════════

CREATE POLICY tasks_firm_boundary ON tasks
    AS RESTRICTIVE FOR ALL
    USING     (firm_id = auth_firm_id())
    WITH CHECK(firm_id = auth_firm_id());

CREATE POLICY tasks_select_admin ON tasks
    AS PERMISSIVE FOR SELECT
    USING (auth_user_role() = 'admin');

CREATE POLICY tasks_select_team ON tasks
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() IN ('partner', 'manager', 'senior')
        AND EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = tasks.case_id
            AND c.team_id = auth_team_id()
        )
    );

CREATE POLICY tasks_select_junior ON tasks
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() = 'junior'
        AND EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = tasks.case_id
            AND c.assigned_junior = auth.uid()
        )
    );

CREATE POLICY tasks_insert ON tasks
    AS PERMISSIVE FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = tasks.case_id
            AND c.team_id = auth_team_id()
        )
    );

CREATE POLICY tasks_update ON tasks
    AS PERMISSIVE FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = tasks.case_id
            AND c.team_id = auth_team_id()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = tasks.case_id
            AND c.team_id = auth_team_id()
        )
    );

-- ════════════════════════════════════════════════════════════════════════════
-- task_edits
-- No direct firm_id or team_id — access inherited from task → case.
-- INSERT-only by application convention (no UPDATE/DELETE endpoint).
-- RLS does not add a formal UPDATE policy; application layer enforces this.
-- ════════════════════════════════════════════════════════════════════════════

CREATE POLICY task_edits_firm_boundary ON task_edits
    AS RESTRICTIVE FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM tasks t
            JOIN cases c ON c.id = t.case_id
            WHERE t.id = task_edits.task_id
            AND c.firm_id = auth_firm_id()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM tasks t
            JOIN cases c ON c.id = t.case_id
            WHERE t.id = task_edits.task_id
            AND c.firm_id = auth_firm_id()
        )
    );

CREATE POLICY task_edits_select_admin ON task_edits
    AS PERMISSIVE FOR SELECT
    USING (auth_user_role() = 'admin');

CREATE POLICY task_edits_select_team ON task_edits
    AS PERMISSIVE FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM tasks t
            JOIN cases c ON c.id = t.case_id
            WHERE t.id = task_edits.task_id
            AND c.team_id = auth_team_id()
        )
    );
    -- No junior-specific branch: junior access is via the team policy when
    -- their case is in the team. If stricter junior isolation is needed,
    -- add a junior branch in Phase 2 using c.assigned_junior = auth.uid().

CREATE POLICY task_edits_insert ON task_edits
    AS PERMISSIVE FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM tasks t
            JOIN cases c ON c.id = t.case_id
            WHERE t.id = task_edits.task_id
            AND c.team_id = auth_team_id()
        )
    );

-- ════════════════════════════════════════════════════════════════════════════
-- case_log
-- Append-only: INSERT is permitted; UPDATE and DELETE are blocked by
-- statement-level triggers (Migration 003) — no UPDATE/DELETE policy needed.
-- Default deny on UPDATE/DELETE is correct; triggers add a second layer.
--
-- RESTRICTIVE uses EXISTS via cases (no direct firm_id on case_log).
-- INSERT WITH CHECK verifies the target case belongs to the user's team —
-- agents log via service role (bypasses RLS) so this only constrains humans.
-- SELECT: all team members can read audit logs for their team's cases.
-- ════════════════════════════════════════════════════════════════════════════

CREATE POLICY case_log_firm_boundary ON case_log
    AS RESTRICTIVE FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = case_log.case_id
            AND c.firm_id = auth_firm_id()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = case_log.case_id
            AND c.firm_id = auth_firm_id()
        )
    );

CREATE POLICY case_log_select_admin ON case_log
    AS PERMISSIVE FOR SELECT
    USING (auth_user_role() = 'admin');

CREATE POLICY case_log_select_team ON case_log
    AS PERMISSIVE FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = case_log.case_id
            AND c.team_id = auth_team_id()
        )
    );

CREATE POLICY case_log_insert ON case_log
    AS PERMISSIVE FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = case_log.case_id
            AND c.team_id = auth_team_id()
        )
    );
    -- Agents (Orchestrator, BookkeepingAgent, BASAgent) write case_log via
    -- the service role (bypasses RLS). This INSERT policy only constrains
    -- humans writing case_log directly — an unlikely but possible path.
    -- The WITH CHECK still prevents a rogue user from logging against another
    -- team's case, even with a valid JWT.


-- ── 20260101000005_grants.sql ───────────────────────────────────
-- Migration 005 — Postgres role grants
-- Tables created via raw SQL migrations do not get Supabase's automatic grants.
-- PostgREST routes requests through the Postgres roles below; without GRANT
-- the service_role API client gets "permission denied" even though it bypasses RLS.
--
-- service_role : ALL  → admin_client() in tests, background jobs, migrations
-- authenticated: DML  → every real user JWT; access shaped by RLS in Migration 004
-- anon         : none → no unauthenticated access to any table

-- Schema usage
GRANT USAGE ON SCHEMA public TO authenticated, anon, service_role;

-- All current tables
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;

-- All current sequences (UUID defaults use gen_random_uuid(), but explicit seqs may exist)
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- Default privileges — applies to tables/sequences created by future migrations
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON TABLES TO service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON SEQUENCES TO service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE ON SEQUENCES TO authenticated;


-- ── 20260101000006_auth_hook.sql ───────────────────────────────────
-- Migration 006 — JWT custom access token hook
-- Injects firm_id, team_id, user_role into the JWT at login time.
-- These are read by auth_firm_id(), auth_team_id(), auth_user_role() in Migration 004.
--
-- AFTER APPLYING THIS MIGRATION:
--   Supabase Dashboard → Authentication → Hooks
--   → "Custom Access Token" → Schema: public, Function: custom_access_token_hook
--   (The function exists in the DB after this migration but is inert until the
--    Dashboard hook is wired. Tests will still fail until the hook is active.)
--
-- DESIGN NOTE: 'role' claim is NOT changed.
-- PostgREST uses the JWT 'role' claim for database role routing (SET ROLE ...).
-- Setting it to 'junior' would cause SET ROLE junior → error (no such Postgres role).
-- App-level role goes in 'user_role' instead. auth_user_role() reads 'user_role'.
-- Supabase keeps 'role: authenticated' for all user JWTs — leave it as-is.

CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    user_rec RECORD;
    claims   jsonb;
BEGIN
    SELECT firm_id, team_id, role AS user_role
    INTO   user_rec
    FROM   public.users
    WHERE  id = (event->>'user_id')::uuid;

    IF FOUND THEN
        claims := event -> 'claims';
        claims := jsonb_set(claims, '{firm_id}',   to_jsonb(user_rec.firm_id::text));
        claims := jsonb_set(claims, '{team_id}',   to_jsonb(user_rec.team_id::text));
        claims := jsonb_set(claims, '{user_role}', to_jsonb(user_rec.user_role));
        RETURN jsonb_set(event, '{claims}', claims);
    END IF;

    -- User not yet in public.users (invited but not onboarded) — return unchanged.
    RETURN event;
END;
$$;

-- supabase_auth_admin is the role that calls hooks during JWT generation.
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION public.custom_access_token_hook TO postgres;
-- Block regular app users from calling the hook directly.
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook FROM PUBLIC;


-- ── 20260101000007_fix_auth_role_claim.sql ───────────────────────────────────
-- Migration 007 — Fix auth_user_role() + test cleanup helper
--
-- Part A: auth_user_role() must read 'user_role', not 'role'.
--   Migration 006 injects the app role as 'user_role' in the JWT.
--   The 'role' claim stays as 'authenticated' for PostgREST routing.
--
-- Part B: test_cleanup_firms() — isolation_test.py teardown helper.
--   The BEFORE DELETE trigger on case_log blocks CASCADE deletion of test data.
--   Solution: use a custom GUC 'app.cleanup_mode' (any role can set user-defined GUCs)
--   that the trigger checks before raising. The trigger update in this migration
--   replaces the one created in Migration 003.

-- ── Part A: auth_user_role ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION auth_user_role() RETURNS TEXT AS $$
    SELECT auth.jwt() ->> 'user_role'
$$ LANGUAGE sql STABLE;

-- ── Part B: updated case_log mutation trigger ──────────────────────────────
-- Replaces the version from Migration 003.
-- Allows deletion when app.cleanup_mode = 'true' (set by test_cleanup_firms).
-- In production, nothing sets this GUC, so the trigger always blocks.

CREATE OR REPLACE FUNCTION prevent_case_log_mutation()
RETURNS TRIGGER AS $$
BEGIN
    IF current_setting('app.cleanup_mode', true) = 'true' THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'case_log is append-only. % is not permitted. Retention policy: 5 years minimum.', TG_OP;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- ── Part C: test cleanup RPC ───────────────────────────────────────────────
-- Sets app.cleanup_mode for the transaction, then deletes firms via CASCADE.
-- The updated trigger (above) allows the deletion.
-- GUC is transaction-local (third arg = true) — resets when function returns.

CREATE OR REPLACE FUNCTION test_cleanup_firms(firm_ids uuid[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM set_config('app.cleanup_mode', 'true', true);
    DELETE FROM firms WHERE id = ANY(firm_ids);
END;
$$;

REVOKE EXECUTE ON FUNCTION test_cleanup_firms FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION test_cleanup_firms TO service_role;


-- ── 20260101000008_storage_rls.sql ───────────────────────────────────
-- Migration 008 — Supabase Storage RLS policies
--
-- Policies on storage.objects cover ALL firm-{firm_id} buckets.
-- Buckets are created dynamically at firm onboarding (Task 1.4, FastAPI).
-- These policies apply automatically when each new bucket is created —
-- no per-firm policy configuration required.
--
-- service_role bypasses RLS → promote_file() (Task 1.4) needs no entry here.
-- Only user JWT paths (authenticated role) are constrained.
--
-- File path format (matches files.storage_path CHECK in Migration 003):
--   bucket : firm-{firm_id}
--   name   : {firm_id}/{client_id}/{period}/{state}/{filename}
--   e.g.     3295e7cb-.../a1b2c3-.../2025-03/raw/statement.pdf
--
-- auth_firm_id() → public.auth_firm_id() (defined in Migration 004, updated 007)
-- NULL-safe: if auth_firm_id() is NULL (no custom claims yet), all policies
-- evaluate to NULL = false → access blocked. No explicit NULL guard needed.

-- ── SELECT ────────────────────────────────────────────────────────────────────
-- Read files only from your own firm's bucket.
-- Fine-grained control (Junior sees only assigned-client files) is enforced at
-- the DB layer via files table RLS (Migration 004) — not duplicated here.

CREATE POLICY storage_objects_select ON storage.objects
    FOR SELECT TO authenticated
    USING (
        bucket_id = 'firm-' || (public.auth_firm_id())::text
    );

-- ── INSERT ────────────────────────────────────────────────────────────────────
-- Upload only to raw/ paths within your firm's bucket.
-- Blocks direct writes to validated/, reviewed/, final/, archived/ via the
-- Storage API. Those paths are written exclusively by service_role via
-- promote_file() (Task 1.4), which bypasses RLS by design.
--
-- Pattern: {firm_id}/{client_id}/{period}/raw/{filename}
-- LIKE '/%/%/raw/%' allows any client_id and period segment before raw/.

CREATE POLICY storage_objects_insert ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'firm-' || (public.auth_firm_id())::text
        AND name LIKE (public.auth_firm_id())::text || '/%/%/raw/%'
    );

-- ── UPDATE: no policy → default deny ─────────────────────────────────────────
-- Files are immutable once uploaded. State transitions create a new file at a
-- new path (INSERT-only model, mirroring files table design in Migration 003).

-- ── DELETE: no policy → default deny ─────────────────────────────────────────
-- 5-year minimum retention requirement. Archival = promote to archived/ path
-- via service_role, never deletion.


-- ── 20260101000009_task_idempotency.sql ───────────────────────────────────
-- Migration 20260101000009: task idempotency guard
--
-- Prevents duplicate active tasks of the same type within a case.
-- An active task is one whose status is pending, in_progress, or waiting_human.
--
-- This is a partial unique index (not a constraint on completed/rejected tasks),
-- so a task can be retried after rejection without violating uniqueness.
--
-- Protects against:
--   (a) task-seeding being called twice for the same case (INSERT conflict → 23505)
--   (b) advance_workflow or case-creation code inserting a duplicate active task
--
-- Does NOT protect against double-UPDATE in advance_workflow (UPDATE does not
-- trigger a unique index violation). Entry-status checks in agent tasks handle that.

CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_case_type_active
    ON tasks (case_id, task_type)
    WHERE status IN ('pending', 'in_progress', 'waiting_human');


-- ── 20260101000010_notifications.sql ───────────────────────────────────
-- Migration 20260101000010: notifications table + Realtime
--
-- Replaces the notify_user_in_app log-only stub.
-- All roles subscribe to notifications WHERE user_id = auth.uid().
-- Fan-out logic (who gets notified for which event) lives in the backend
-- notify_user_in_app Celery task — frontend has no role awareness required.

CREATE TABLE notifications (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid        NOT NULL REFERENCES users(id)  ON DELETE CASCADE,
    case_id     uuid        NOT NULL REFERENCES cases(id)  ON DELETE CASCADE,
    task_id     uuid        NOT NULL REFERENCES tasks(id)  ON DELETE CASCADE,
    message     text        NOT NULL,
    action_url  text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    read_at     timestamptz
);

-- Efficient query for "my unread notifications" (ordered newest-first)
CREATE INDEX idx_notifications_user_unread
    ON notifications (user_id, created_at DESC)
    WHERE read_at IS NULL;

-- ── RLS ───────────────────────────────────────────────────────────────────────
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

-- user_id = auth.uid() is already the tightest possible scope (more specific
-- than firm_id), so a separate RESTRICTIVE firm boundary is not needed here.
CREATE POLICY notifications_own_select ON notifications
    AS PERMISSIVE FOR SELECT
    USING (user_id = auth.uid());

CREATE POLICY notifications_own_update ON notifications
    AS PERMISSIVE FOR UPDATE
    USING (user_id = auth.uid());

-- INSERT is via admin/service-role client (notify_user_in_app Celery task).
-- No user INSERT policy — prevents clients from spoofing notifications.

-- ── Realtime ──────────────────────────────────────────────────────────────────
-- Add to the default Supabase Realtime publication so the frontend channel
-- subscription receives postgres_changes events for INSERT.
ALTER PUBLICATION supabase_realtime ADD TABLE notifications;


-- ── 20260101000011_client_gst_fields.sql ───────────────────────────────────
-- Migration 011 — Add GST registration fields to clients
--
-- gst_registered      : boolean — persisted from ABN lookup at client creation
-- gst_registered_from : date    — GST registration date from ABR
--
-- Both are nullable: existing clients and clients without ABN lookup data
-- remain valid. BAS workpaper header displays these when present.

ALTER TABLE clients
    ADD COLUMN gst_registered      BOOLEAN,
    ADD COLUMN gst_registered_from DATE;

COMMENT ON COLUMN clients.gst_registered      IS 'Whether the entity is GST registered — sourced from ABR at client creation';
COMMENT ON COLUMN clients.gst_registered_from IS 'GST registration effective date — sourced from ABR at client creation';


-- ── 20260101000012_add_json_file_type.sql ───────────────────────────────────
-- Migration 012: Allow 'json' as a valid file_type for agent-generated BAS draft files.
-- The original check constraint in migration 003 only listed pdf/xlsx/xls/csv.

ALTER TABLE files
  DROP CONSTRAINT IF EXISTS files_file_type_check;

ALTER TABLE files
  ADD CONSTRAINT files_file_type_check
  CHECK (file_type IN ('pdf', 'xlsx', 'xls', 'csv', 'json'));


-- ── 20260101000013_clients_status_open_closed.sql ───────────────────────────────────
-- Migration 013: Rename client status open/closed
--
-- Old values: pending | active | inactive
-- New values: open (client being serviced) | closed (service ended)
--
-- Data migration: pending + active → open, inactive → closed
-- activated_at is now set on registration and retained when closed.

-- 1. Drop ALL old constraints — clients_status_check MUST be dropped before
--    the UPDATE or the INSERT of 'open'/'closed' will be rejected by the old CHECK.
ALTER TABLE clients DROP CONSTRAINT IF EXISTS chk_active_client_has_junior;
ALTER TABLE clients DROP CONSTRAINT IF EXISTS chk_activated_at_consistency;
ALTER TABLE clients DROP CONSTRAINT IF EXISTS clients_status_check;

-- 2. Migrate existing rows (old constraint is now gone)
UPDATE clients SET status = 'open'   WHERE status IN ('pending', 'active');
UPDATE clients SET status = 'closed' WHERE status = 'inactive';

-- 3. Backfill activated_at for any rows that lack it (old pending clients)
UPDATE clients SET activated_at = created_at WHERE activated_at IS NULL;

-- 4. Add the new status CHECK constraint

ALTER TABLE clients ADD CONSTRAINT clients_status_check
    CHECK (status IN ('open', 'closed'));

-- 5. All clients now have activated_at (set on registration, retained on close)
ALTER TABLE clients ADD CONSTRAINT chk_activated_at_required
    CHECK (activated_at IS NOT NULL);

-- 6. Update column default
ALTER TABLE clients ALTER COLUMN status SET DEFAULT 'open';


-- ── 20260101000014_remove_bank_statement_case_type.sql ───────────────────────────────────
-- Migration 014 — Remove bank_statement as a case_type
--
-- bank_statement was never a distinct business line. It ran the identical
-- task chain as bas_gst. All staging case data has been manually cleared,
-- so no data migration is required — this is a constraint-only cleanup.
--
-- Changes:
--   1. is_mvp_active_case_type() function — remove bank_statement
--   2. cases.case_type CHECK constraint — remove bank_statement
--   3. cases.is_mvp_active generated column — remove bank_statement
--   4. tasks.case_type CHECK constraint — remove bank_statement (must stay in sync)

-- ── 1. Update helper function ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION is_mvp_active_case_type(ct TEXT) RETURNS BOOLEAN AS $$
BEGIN
    RETURN ct IN ('bas_gst');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ── 2. cases.case_type CHECK constraint ───────────────────────────────────────

ALTER TABLE cases DROP CONSTRAINT IF EXISTS cases_case_type_check;

ALTER TABLE cases
    ADD CONSTRAINT cases_case_type_check
    CHECK (case_type IN (
        -- MVP active
        'bas_gst',
        -- Reserved — not implemented in MVP; UI shows "Coming soon"
        'tax_return', 'payroll', 'smsf',
        'asic', 'audit', 'advisory'
    ));

-- ── 3. cases.is_mvp_active generated column ──────────────────────────────────
-- Generated column expressions cannot be altered in-place; must drop + re-add.

ALTER TABLE cases DROP COLUMN is_mvp_active;

ALTER TABLE cases
    ADD COLUMN is_mvp_active BOOLEAN NOT NULL
        GENERATED ALWAYS AS (case_type IN ('bas_gst')) STORED;

-- ── 4. tasks.case_type CHECK constraint ───────────────────────────────────────
-- tasks.case_type mirrors cases.case_type (set by trigger). Must stay in sync.

ALTER TABLE tasks DROP CONSTRAINT IF EXISTS tasks_case_type_check;

ALTER TABLE tasks
    ADD CONSTRAINT tasks_case_type_check
    CHECK (case_type IN (
        'bas_gst',
        'tax_return', 'payroll', 'smsf',
        'asic', 'audit', 'advisory'
    ));


-- ── 20260101000015_add_senior_bas_review_task_type.sql ───────────────────────────────────
-- Migration 015 — Add senior_bas_review to tasks.task_type CHECK constraint
--
-- senior_bas_review is inserted between bas_draft and manager_review for teams
-- with approval_chain.senior_review = true. The task_type CHECK constraint must
-- include it or any case creation for such teams fails with a constraint violation.

ALTER TABLE tasks DROP CONSTRAINT IF EXISTS tasks_task_type_check;

ALTER TABLE tasks
    ADD CONSTRAINT tasks_task_type_check
    CHECK (task_type IN (
        'extract',
        'validate_extraction',
        'gst_prep',
        'validate_gst',
        'senior_review',
        'bas_draft',
        'senior_bas_review',
        'manager_review',
        'client_confirm',
        'certify'
    ));


-- ── 20260101000016_add_account_to_files.sql ───────────────────────────────────
-- Migration 016: Add account column to files table
--
-- Files that represent bank statements can now be tagged with a
-- "Bank / Account" label (e.g. "CBA Operating", "ANZ Payroll").
-- This label is injected into every extracted CSV row at extraction time
-- and flows through validated/ → processed/ → reviewed/ unchanged.
-- calculate_bas_summary() groups by account for multi-account BAS workpapers.
--
-- Nullable by design: single-account cases omit the field entirely.

ALTER TABLE files ADD COLUMN IF NOT EXISTS account TEXT DEFAULT NULL;


-- ── 20260101000017_add_engagement_date.sql ───────────────────────────────────
-- Migration 017: Add engagement_date to clients
-- engagement_date: the date the client formally engaged the accounting firm
-- (when the engagement letter / service agreement was signed).
-- Separate from activated_at (system activation timestamp, set by staff action).

ALTER TABLE clients ADD COLUMN engagement_date DATE;


-- ── 20260101000018_add_contact_email.sql ───────────────────────────────────
-- Migration 018: Add contact_email to clients
-- Stores the primary accounting contact email for client communication
-- (separate from directors.email which holds legal director emails)

ALTER TABLE clients ADD COLUMN IF NOT EXISTS contact_email TEXT;


-- ── 20260101000019_hook_rls_fix.sql ───────────────────────────────────
-- Migration 019: Fix auth hook RLS + VOLATILE + EXCEPTION handler
--
-- Problem: custom_access_token_hook (SECURITY DEFINER, runs as postgres) was
-- blocked by the RESTRICTIVE firm_boundary policy on users (no TO clause →
-- applied to all roles including postgres).  postgres has no BYPASSRLS in
-- Supabase's managed environment, so the SELECT returned 0 rows and GoTrue
-- received an event without firm_id/team_id/user_role claims.
--
-- Fix 1: Scope users_firm_boundary RESTRICTIVE policy to authenticated + anon only.
-- Fix 2: Add PERMISSIVE SELECT policy for postgres so the hook can read all users.
-- Fix 3: Update hook to VOLATILE + EXCEPTION WHEN OTHERS (defensive fallback).

-- ── 1. Restrict firm_boundary to authenticated/anon roles only ─────────────
DROP POLICY IF EXISTS users_firm_boundary ON users;

CREATE POLICY users_firm_boundary ON users
    AS RESTRICTIVE FOR ALL
    TO authenticated, anon
    USING     (firm_id = auth_firm_id())
    WITH CHECK(firm_id = auth_firm_id());

-- ── 2. Allow postgres (hook's SECURITY DEFINER role) to read all users ─────
DROP POLICY IF EXISTS users_postgres_internal ON users;

CREATE POLICY users_postgres_internal ON users
    AS PERMISSIVE FOR SELECT
    TO postgres
    USING (true);

-- ── 3. Update hook: VOLATILE + EXCEPTION handler ───────────────────────────
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    user_rec RECORD;
    claims   jsonb;
BEGIN
    SELECT firm_id, team_id, role AS user_role INTO user_rec
    FROM public.users WHERE id = (event->>'user_id')::uuid;
    IF FOUND THEN
        claims := event -> 'claims';
        claims := jsonb_set(claims, '{firm_id}',   to_jsonb(user_rec.firm_id::text));
        claims := jsonb_set(claims, '{team_id}',   to_jsonb(user_rec.team_id::text));
        claims := jsonb_set(claims, '{user_role}', to_jsonb(user_rec.user_role));
        RETURN jsonb_set(event, '{claims}', claims);
    END IF;
    RETURN event;
EXCEPTION WHEN OTHERS THEN
    -- Graceful fallback: return event unchanged rather than failing login with 500.
    -- JWT will lack custom claims; app-level RLS will block data access.
    RETURN event;
END;
$$;

GRANT EXECUTE ON FUNCTION public.custom_access_token_hook TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.custom_access_token_hook FROM PUBLIC;


-- ── 20260101000020_add_owner_role.sql ───────────────────────────────────
-- Migration 020: Owner role — firm-wide access, bypasses team_id boundary
-- Owner = firm registrant / managing partner. Supersedes admin + partner.
-- RESTRICTIVE firm_boundary policies still apply (firm_id = auth_firm_id()).
-- These PERMISSIVE policies give owner access to all rows within the firm.

-- Extend role check constraint to include 'owner'
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check
  CHECK (role IN ('owner', 'admin', 'partner', 'manager', 'senior', 'junior'));

CREATE POLICY users_owner ON users
  AS PERMISSIVE FOR ALL TO authenticated
  USING (auth_user_role() = 'owner');

CREATE POLICY teams_owner ON teams
  AS PERMISSIVE FOR ALL TO authenticated
  USING (auth_user_role() = 'owner');

CREATE POLICY clients_owner ON clients
  AS PERMISSIVE FOR ALL TO authenticated
  USING (auth_user_role() = 'owner');

CREATE POLICY cases_owner ON cases
  AS PERMISSIVE FOR ALL TO authenticated
  USING (auth_user_role() = 'owner');

CREATE POLICY tasks_owner ON tasks
  AS PERMISSIVE FOR ALL TO authenticated
  USING (auth_user_role() = 'owner');

CREATE POLICY files_owner ON files
  AS PERMISSIVE FOR ALL TO authenticated
  USING (auth_user_role() = 'owner');

CREATE POLICY case_log_owner ON case_log
  AS PERMISSIVE FOR ALL TO authenticated
  USING (auth_user_role() = 'owner');

CREATE POLICY task_edits_owner ON task_edits
  AS PERMISSIVE FOR ALL TO authenticated
  USING (auth_user_role() = 'owner');


-- ── 20260101000021_owner_policy_gaps.sql ───────────────────────────────────
-- Migration 021: Owner policy gaps + task_edits junior isolation
--
-- Gaps found in Migration 020:
--   directors, sla_profiles, coding_rule_sets, firms
--   were missing owner PERMISSIVE policies.
--
-- task_edits_select_team had no junior branch — junior could query
--   team-wide edits (not just their own cases). Frontend blocked
--   via ProtectedRoute, but RLS should enforce it too.

-- ── owner policies for missing tables ────────────────────────────────────────

CREATE POLICY directors_owner ON directors
    AS PERMISSIVE FOR ALL TO authenticated
    USING (auth_user_role() = 'owner');

CREATE POLICY sla_profiles_owner ON sla_profiles
    AS PERMISSIVE FOR ALL TO authenticated
    USING (auth_user_role() = 'owner');

CREATE POLICY coding_rule_sets_owner ON coding_rule_sets
    AS PERMISSIVE FOR ALL TO authenticated
    USING (auth_user_role() = 'owner');

CREATE POLICY firms_owner ON firms
    AS PERMISSIVE FOR ALL TO authenticated
    USING (id = auth_firm_id() AND auth_user_role() = 'owner');

-- ── task_edits junior isolation ───────────────────────────────────────────────
-- Replace the team policy (no role filter) with two explicit branches:
--   senior/manager/partner → team-scoped (existing intent, now explicit)
--   junior               → only cases assigned to them (matches tasks/cases)

DROP POLICY IF EXISTS task_edits_select_team ON task_edits;

CREATE POLICY task_edits_select_team ON task_edits
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() IN ('partner', 'manager', 'senior')
        AND EXISTS (
            SELECT 1 FROM tasks t
            JOIN cases c ON c.id = t.case_id
            WHERE t.id = task_edits.task_id
            AND c.team_id = auth_team_id()
        )
    );

CREATE POLICY task_edits_select_junior ON task_edits
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() = 'junior'
        AND EXISTS (
            SELECT 1 FROM tasks t
            JOIN cases c ON c.id = t.case_id
            WHERE t.id = task_edits.task_id
            AND c.assigned_junior = auth.uid()
        )
    );


-- ── 20260101000022_case_documents.sql ───────────────────────────────────
-- Migration 022: case_documents table
-- Stores client-provided query evidence (WeChat screenshots, explanations,
-- contracts, invoices supplied in response to accountant queries).
-- Agents NEVER read this table. Pipeline documents remain in the files table.

CREATE TABLE IF NOT EXISTS case_documents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id         UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    firm_id         UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
    query_id        UUID,           -- null until Query module built (Phase N)
    document_type   TEXT NOT NULL,  -- receipt | invoice | payroll | ato_statement
                                    -- | screenshot | contract | ato_receipt | other
    file_name       TEXT NOT NULL,
    storage_path    TEXT NOT NULL,  -- {firm_id}/{client_id}/{period}/evidence/{ts}_{name}
    note            TEXT,           -- optional accountant note on upload
    uploaded_by     UUID REFERENCES users(id),
    uploaded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_case_documents_case_id  ON case_documents(case_id);
CREATE INDEX IF NOT EXISTS idx_case_documents_firm_id  ON case_documents(firm_id);
CREATE INDEX IF NOT EXISTS idx_case_documents_query_id ON case_documents(query_id)
    WHERE query_id IS NOT NULL;

-- RLS
ALTER TABLE case_documents ENABLE ROW LEVEL SECURITY;

-- Outer fence: firm boundary (RESTRICTIVE — cannot be overridden by any PERMISSIVE policy)
CREATE POLICY case_documents_firm_boundary ON case_documents
    AS RESTRICTIVE FOR ALL
    USING (firm_id = auth_firm_id());

-- Read: any team member in the same firm (firm boundary already guaranteed above)
CREATE POLICY case_documents_select ON case_documents
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() IN ('owner', 'admin', 'partner', 'manager', 'senior', 'junior')
    );

-- Insert: any authenticated team member
CREATE POLICY case_documents_insert ON case_documents
    AS PERMISSIVE FOR INSERT
    WITH CHECK (
        firm_id = auth_firm_id()
        AND auth_user_role() IN ('owner', 'admin', 'partner', 'manager', 'senior', 'junior')
    );

-- Delete: uploader, senior+, or admin/owner
CREATE POLICY case_documents_delete ON case_documents
    AS PERMISSIVE FOR DELETE
    USING (
        uploaded_by = auth.uid()
        OR auth_user_role() IN ('owner', 'admin', 'partner', 'manager', 'senior')
    );

-- Grant to authenticated role
GRANT SELECT, INSERT, DELETE ON case_documents TO authenticated;


-- ── 20260101000023_client_queries.sql ───────────────────────────────────
-- Migration 023: client query links + queries
-- Accountant generates a magic link → client opens in browser → fills form → submits

CREATE TABLE IF NOT EXISTS client_query_links (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id     UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    firm_id     UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
    token       TEXT NOT NULL UNIQUE DEFAULT gen_random_uuid()::text,
    password    TEXT NOT NULL,          -- 4-digit PIN, set by accountant
    expires_at  TIMESTAMPTZ NOT NULL,   -- 7 days from creation
    submitted_at TIMESTAMPTZ,           -- when client submitted answers
    created_by  UUID REFERENCES users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS queries (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id              UUID NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    firm_id              UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
    link_id              UUID REFERENCES client_query_links(id) ON DELETE SET NULL,
    transaction_row_ref  TEXT,          -- null = case-level query
    merchant             TEXT,
    amount               TEXT,
    query_text           TEXT NOT NULL, -- from explanation
    context_note         TEXT,          -- from accountant note
    status               TEXT NOT NULL DEFAULT 'pending',
                                        -- pending | answered | resolved
    client_answer        TEXT,
    answered_at          TIMESTAMPTZ,
    resolved_by          UUID REFERENCES users(id),
    resolved_at          TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_queries_case_id  ON queries(case_id);
CREATE INDEX IF NOT EXISTS idx_queries_link_id  ON queries(link_id);
CREATE INDEX IF NOT EXISTS idx_client_query_links_token ON client_query_links(token);

-- RLS on client_query_links (firm-scoped, accountant-only)
ALTER TABLE client_query_links ENABLE ROW LEVEL SECURITY;

CREATE POLICY cql_firm_boundary ON client_query_links
    AS RESTRICTIVE FOR ALL USING (firm_id = auth_firm_id());

CREATE POLICY cql_select ON client_query_links
    AS PERMISSIVE FOR SELECT
    USING (auth_user_role() IN ('owner','admin','partner','manager','senior','junior'));

CREATE POLICY cql_insert ON client_query_links
    AS PERMISSIVE FOR INSERT
    WITH CHECK (firm_id = auth_firm_id()
        AND auth_user_role() IN ('owner','admin','partner','manager','senior','junior'));

-- RLS on queries (firm-scoped, accountant-only)
ALTER TABLE queries ENABLE ROW LEVEL SECURITY;

CREATE POLICY queries_firm_boundary ON queries
    AS RESTRICTIVE FOR ALL USING (firm_id = auth_firm_id());

CREATE POLICY queries_select ON queries
    AS PERMISSIVE FOR SELECT
    USING (auth_user_role() IN ('owner','admin','partner','manager','senior','junior'));

CREATE POLICY queries_insert ON queries
    AS PERMISSIVE FOR INSERT
    WITH CHECK (firm_id = auth_firm_id()
        AND auth_user_role() IN ('owner','admin','partner','manager','senior','junior'));

CREATE POLICY queries_update ON queries
    AS PERMISSIVE FOR UPDATE
    USING (auth_user_role() IN ('owner','admin','partner','manager','senior','junior'));

GRANT SELECT, INSERT, UPDATE ON client_query_links TO authenticated;
GRANT SELECT, INSERT, UPDATE ON queries TO authenticated;


-- ── 20260101000024_queries_transaction_detail.sql ───────────────────────────────────
-- Migration 024: Add transaction detail fields to queries table
-- So client can see the exact bank row they're being asked about.

ALTER TABLE queries ADD COLUMN IF NOT EXISTS date        TEXT;
ALTER TABLE queries ADD COLUMN IF NOT EXISTS description TEXT;
ALTER TABLE queries ADD COLUMN IF NOT EXISTS account     TEXT;


-- ── 20260101000025_case_documents_query_fk.sql ───────────────────────────────────
-- Migration 025: Add FK constraint case_documents.query_id → queries.id
-- Required for PostgREST embedded join: .select("*, docs:case_documents(id, file_name)")
-- ON DELETE SET NULL: if a query is deleted, document remains as case evidence.

ALTER TABLE case_documents
  ADD CONSTRAINT fk_case_documents_query
  FOREIGN KEY (query_id) REFERENCES queries(id) ON DELETE SET NULL;


-- ── 20260101000026_case_log_client_query_actions.sql ───────────────────────────────────
-- Migration 026: extend case_log action check constraint to include client query actions
-- Root cause: create_query_link and submit_query_answers write case_log with
-- 'client_query_sent', 'client_query_answered', 'client_query_revoked' — all blocked
-- by the original constraint defined inline in migration 003.

ALTER TABLE case_log DROP CONSTRAINT IF EXISTS case_log_action_check;

ALTER TABLE case_log ADD CONSTRAINT case_log_action_check CHECK (action IN (
    -- Orchestrator routing decisions
    'delegate', 'promote', 'pause', 'resume', 'reject_route',
    -- Human actions
    'validate', 'approve', 'reject', 'certify',
    -- Agent completion signals
    'extraction_complete', 'gst_prep_complete', 'bas_draft_complete',
    -- Orchestrator diagnostic (speculative, never triggers behaviour)
    'diagnostic_observation',
    -- Client query audit trail
    'client_query_sent', 'client_query_answered', 'client_query_revoked'
));


-- ── 20260101000027_case_log_client_actor_type.sql ───────────────────────────────────
-- Migration 027: add 'client' actor_type to case_log
-- Needed for client_query_answered entries where actor has no user account (no actor_id).
-- 'client' is distinct from 'human' (staff) — client submissions go through public magic link.

-- Extend the actor_type CHECK constraint
ALTER TABLE case_log DROP CONSTRAINT IF EXISTS case_log_actor_type_check;
ALTER TABLE case_log ADD CONSTRAINT case_log_actor_type_check CHECK (
    actor_type IN ('human', 'hermes_orchestrator', 'bookkeeping_agent', 'bas_agent', 'client')
);

-- The existing chk_case_log_human_has_actor only applies to 'human' — 'client' is exempt.
-- No change needed to that constraint.


-- ── 20260101000028_client_confirm_links.sql ───────────────────────────────────
-- Migration 028: client_confirm_links table + extend case_log constraints
-- Supports the client BAS confirmation flow via magic link.
-- Manager (full chain) or Senior (minimal chain) sends BAS PDF to client,
-- client returns signed document, accountant confirms to close the loop.

-- ── 1. client_confirm_links table ──────────────────────────────────────────

CREATE TABLE IF NOT EXISTS client_confirm_links (
    id              UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
    case_id         UUID        NOT NULL REFERENCES cases(id) ON DELETE CASCADE,
    firm_id         UUID        NOT NULL REFERENCES firms(id),
    token           TEXT        NOT NULL UNIQUE,
    password        TEXT        NOT NULL,
    outbound_doc_id UUID        REFERENCES case_documents(id) ON DELETE SET NULL,
    signed_doc_id   UUID        REFERENCES case_documents(id) ON DELETE SET NULL,
    expires_at      TIMESTAMPTZ NOT NULL,
    submitted_at    TIMESTAMPTZ,   -- when client uploaded signed document
    confirmed_at    TIMESTAMPTZ,   -- when accountant confirmed receipt
    created_by      UUID        REFERENCES users(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── 2. RLS ─────────────────────────────────────────────────────────────────

ALTER TABLE client_confirm_links ENABLE ROW LEVEL SECURITY;

CREATE POLICY client_confirm_links_firm_boundary ON client_confirm_links
    AS RESTRICTIVE FOR ALL
    USING (firm_id = auth_firm_id());

CREATE POLICY client_confirm_links_team_select ON client_confirm_links
    AS PERMISSIVE FOR SELECT
    USING (
        case_id IN (
            SELECT id FROM cases WHERE team_id = auth_team_id()
        )
        OR auth_user_role() IN ('owner', 'admin')
    );

CREATE POLICY client_confirm_links_team_insert ON client_confirm_links
    AS PERMISSIVE FOR INSERT
    WITH CHECK (
        firm_id = auth_firm_id()
        AND (
            case_id IN (SELECT id FROM cases WHERE team_id = auth_team_id())
            OR auth_user_role() IN ('owner', 'admin')
        )
    );

CREATE POLICY client_confirm_links_team_update ON client_confirm_links
    AS PERMISSIVE FOR UPDATE
    USING (
        case_id IN (
            SELECT id FROM cases WHERE team_id = auth_team_id()
        )
        OR auth_user_role() IN ('owner', 'admin')
    );

CREATE POLICY client_confirm_links_team_delete ON client_confirm_links
    AS PERMISSIVE FOR DELETE
    USING (
        case_id IN (
            SELECT id FROM cases WHERE team_id = auth_team_id()
        )
        OR auth_user_role() IN ('owner', 'admin')
    );

-- ── 3. Extend case_log action CHECK ────────────────────────────────────────

ALTER TABLE case_log DROP CONSTRAINT IF EXISTS case_log_action_check;
ALTER TABLE case_log ADD CONSTRAINT case_log_action_check CHECK (
    action IN (
        'delegate', 'promote', 'pause', 'resume', 'reject_route',
        'validate', 'approve', 'reject', 'certify',
        'extraction_complete', 'gst_prep_complete', 'bas_draft_complete',
        'diagnostic_observation',
        'client_query_sent', 'client_query_answered', 'client_query_revoked',
        'client_confirm_sent', 'client_confirmation_received'
    )
);


-- ── 20260101000029_firm_modules.sql ───────────────────────────────────
-- Migration 029: firm_modules — per-firm module activation
-- Firms activate only the modules they need (bas_gst, payroll, tax_returns, smsf, asic, advisory)

CREATE TABLE firm_modules (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  firm_id         UUID REFERENCES firms(id) ON DELETE CASCADE NOT NULL,
  module_name     TEXT NOT NULL CHECK (
    module_name IN ('bas_gst', 'payroll', 'tax_individual', 'tax_company', 'smsf', 'asic', 'advisory')
  ),
  active          BOOLEAN DEFAULT true,
  activated_at    TIMESTAMPTZ DEFAULT NOW(),
  activated_by    UUID REFERENCES users(id) ON DELETE SET NULL
);

CREATE UNIQUE INDEX idx_firm_modules_firm_module ON firm_modules(firm_id, module_name);

ALTER TABLE firm_modules ENABLE ROW LEVEL SECURITY;

-- Firm boundary — restrictive, cannot be overridden
CREATE POLICY firm_modules_firm_boundary ON firm_modules
  AS RESTRICTIVE FOR ALL
  USING (firm_id = auth_firm_id());

-- All authenticated users can read (controls what shows in UI)
CREATE POLICY firm_modules_read ON firm_modules
  AS PERMISSIVE FOR SELECT
  USING (firm_id = auth_firm_id());

-- Owner / admin / partner can manage modules
CREATE POLICY firm_modules_manage ON firm_modules
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (auth_user_role() IN ('owner', 'admin', 'partner'));

CREATE POLICY firm_modules_update ON firm_modules
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (auth_user_role() IN ('owner', 'admin', 'partner'));

CREATE POLICY firm_modules_delete ON firm_modules
  AS PERMISSIVE FOR DELETE TO authenticated
  USING (auth_user_role() IN ('owner', 'admin', 'partner'));

-- Seed bas_gst as active for all existing firms
INSERT INTO firm_modules (firm_id, module_name, active)
SELECT id, 'bas_gst', true FROM firms
ON CONFLICT (firm_id, module_name) DO NOTHING;


-- ── 20260101000030_xero_connections.sql ───────────────────────────────────
-- Migration 030: Xero OAuth connections + client tenant mapping

CREATE TABLE IF NOT EXISTS xero_connections (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    firm_id         UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
    access_token    TEXT NOT NULL,
    refresh_token   TEXT NOT NULL,
    token_expiry    TIMESTAMPTZ NOT NULL,
    scopes          TEXT DEFAULT '',
    connected_by    UUID REFERENCES users(id) ON DELETE SET NULL,
    connected_at    TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (firm_id)  -- one Xero connection per firm
);

-- Client → Xero tenant mapping
ALTER TABLE clients ADD COLUMN IF NOT EXISTS xero_tenant_id TEXT;
ALTER TABLE clients ADD COLUMN IF NOT EXISTS xero_tenant_name TEXT;

-- RLS
ALTER TABLE xero_connections ENABLE ROW LEVEL SECURITY;

-- Firm boundary — RESTRICTIVE
CREATE POLICY xero_connections_firm_boundary ON xero_connections
    AS RESTRICTIVE FOR ALL
    USING (firm_id = auth_firm_id());

-- Read: all authenticated users in firm
CREATE POLICY xero_connections_select ON xero_connections
    AS PERMISSIVE FOR SELECT
    USING (true);

-- Write: owner/admin/partner only
CREATE POLICY xero_connections_manage ON xero_connections
    AS PERMISSIVE FOR ALL
    USING (auth_user_role() IN ('owner', 'admin', 'partner'));


-- ── 20260101000031_approval_chain_manager_push_xero.sql ───────────────────────────────────
-- Migration 031: add manager_can_push_xero to teams.approval_chain
-- Backfills existing rows with the default value (false = Partner only)

UPDATE teams
SET approval_chain = approval_chain || '{"manager_can_push_xero": false}'::jsonb
WHERE approval_chain IS NOT NULL
  AND NOT (approval_chain ? 'manager_can_push_xero');


-- ── 20260101000032_qbo_connections.sql ───────────────────────────────────
-- Migration 032: QuickBooks Online OAuth connections
-- Mirrors xero_connections table structure

CREATE TABLE IF NOT EXISTS qbo_firm_connections (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    firm_id        UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
    access_token   TEXT NOT NULL,
    refresh_token  TEXT NOT NULL,
    token_expiry   TIMESTAMPTZ NOT NULL,
    realm_id       TEXT NOT NULL,          -- QBO company ID (from OAuth callback)
    company_name   TEXT,                   -- fetched from QBO CompanyInfo
    scopes         TEXT DEFAULT '',
    connected_at   TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (firm_id)
);

-- RLS
ALTER TABLE qbo_firm_connections ENABLE ROW LEVEL SECURITY;

CREATE POLICY qbo_connections_firm_boundary ON qbo_firm_connections
    AS RESTRICTIVE FOR ALL
    USING (firm_id = auth_firm_id());

CREATE POLICY qbo_connections_manage ON qbo_firm_connections
    AS PERMISSIVE FOR ALL
    USING (auth_user_role() IN ('owner', 'admin', 'partner'));

-- Per-client QBO company mapping
ALTER TABLE clients
    ADD COLUMN IF NOT EXISTS qbo_realm_id    TEXT,
    ADD COLUMN IF NOT EXISTS qbo_company_name TEXT;


-- ── 20260101000033_auto_push_columns.sql ───────────────────────────────────
-- Migration 033: Auto-push flags for Xero / QuickBooks per client
-- Set by owner/admin at client-setup time; certify task checks these and pushes automatically

ALTER TABLE clients
    ADD COLUMN IF NOT EXISTS xero_auto_push BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS qbo_auto_push  BOOLEAN NOT NULL DEFAULT FALSE;


-- ── 20260101000034_xero_qbo_firm_level.sql ───────────────────────────────────
-- Migration 034: Firm-level Xero/QBO configuration
-- Adds selected_tenant_id + tenant_name + auto_push to xero_connections
-- Adds auto_push to qbo_firm_connections
-- Drops per-client Xero/QBO columns (moved to firm level)

ALTER TABLE xero_connections
  ADD COLUMN IF NOT EXISTS selected_tenant_id   TEXT,
  ADD COLUMN IF NOT EXISTS selected_tenant_name TEXT,
  ADD COLUMN IF NOT EXISTS auto_push            BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE qbo_firm_connections
  ADD COLUMN IF NOT EXISTS auto_push BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE clients
  DROP COLUMN IF EXISTS xero_tenant_id,
  DROP COLUMN IF EXISTS xero_tenant_name,
  DROP COLUMN IF EXISTS xero_auto_push,
  DROP COLUMN IF EXISTS qbo_realm_id,
  DROP COLUMN IF EXISTS qbo_company_name,
  DROP COLUMN IF EXISTS qbo_auto_push;


-- ── 20260101000035_byok_ai.sql ───────────────────────────────────
-- Migration 035: BYOK (Bring Your Own Key) AI configuration per firm
-- Firms can optionally supply their own LLM API key (Anthropic/OpenAI/Google).
-- Key is encrypted at rest via Fernet (ENCRYPTION_KEY Railway env var).
-- ai_api_key_encrypted is NEVER returned in API responses.

ALTER TABLE firms
  ADD COLUMN IF NOT EXISTS ai_provider        TEXT,    -- 'anthropic' | 'openai' | 'google'
  ADD COLUMN IF NOT EXISTS ai_model           TEXT,    -- null = use platform BAS_AGENT_MODEL default
  ADD COLUMN IF NOT EXISTS ai_api_key_encrypted TEXT;  -- Fernet-encrypted key; null = use platform key


-- ── 20260101000036_billing.sql ───────────────────────────────────
-- Migration 036: Billing — subscription plan names + extraction tracking + credits

-- 1. Update subscription_plan constraint to match new plan names
ALTER TABLE firms DROP CONSTRAINT IF EXISTS firms_subscription_plan_check;
ALTER TABLE firms ADD CONSTRAINT firms_subscription_plan_check
  CHECK (subscription_plan IN ('starter', 'growth', 'scale'));

-- Migrate any existing rows using old values
UPDATE firms SET subscription_plan = 'starter'
  WHERE subscription_plan IN ('professional', 'enterprise');

-- 2. Monthly extraction counter (reset by Celery beat on 1st of each month)
ALTER TABLE firms
  ADD COLUMN IF NOT EXISTS extractions_used_this_month INT NOT NULL DEFAULT 0;

-- 3. Top-up credits table
CREATE TABLE IF NOT EXISTS firm_extraction_credits (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  firm_id       UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
  amount        INT  NOT NULL CHECK (amount > 0),
  remaining     INT  NOT NULL CHECK (remaining >= 0),
  purchased_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ,
  stripe_payment_intent TEXT
);

CREATE INDEX IF NOT EXISTS idx_firm_credits_firm ON firm_extraction_credits(firm_id)
  WHERE remaining > 0;

-- RLS
ALTER TABLE firm_extraction_credits ENABLE ROW LEVEL SECURITY;

CREATE POLICY firm_extraction_credits_boundary ON firm_extraction_credits
  AS RESTRICTIVE FOR ALL
  USING (firm_id = auth_firm_id());

CREATE POLICY firm_extraction_credits_owner_read ON firm_extraction_credits
  AS PERMISSIVE FOR SELECT
  USING (auth_user_role() IN ('owner', 'admin'));


-- ── 20260101000037_billing_anchor.sql ───────────────────────────────────
-- Migration 037: Billing anchor day (anniversary-based extraction reset)
-- billing_anchor_day: day-of-month on which the firm's billing cycle resets (1–28)
-- Capped at 28 to avoid Feb 29/30/31 edge cases.
-- Set at firm registration time; Stripe webhook will update on plan change.

ALTER TABLE firms
  ADD COLUMN IF NOT EXISTS billing_anchor_day INT NOT NULL DEFAULT 1
  CHECK (billing_anchor_day BETWEEN 1 AND 28);


-- ── 20260101000038_increment_extractions_rpc.sql ───────────────────────────────────
-- Migration 038: atomic extraction counter increment RPC
-- Called by Celery run_extraction task after each successful Orvexa API call.
-- Uses UPDATE ... SET x = x + 1 to avoid read-modify-write races under concurrent workers.

CREATE OR REPLACE FUNCTION increment_firm_extractions(p_firm_id UUID)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
  UPDATE firms
  SET extractions_used_this_month = extractions_used_this_month + 1
  WHERE id = p_firm_id;
$$;

-- Only service_role (Celery admin client) can call this — not user JWT
REVOKE ALL ON FUNCTION increment_firm_extractions(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION increment_firm_extractions(UUID) TO service_role;


-- ── 20260101000039_stripe_fields.sql ───────────────────────────────────
-- Migration 039: Stripe billing fields on firms table
ALTER TABLE firms
  ADD COLUMN IF NOT EXISTS stripe_customer_id    TEXT,
  ADD COLUMN IF NOT EXISTS stripe_subscription_id TEXT,
  ADD COLUMN IF NOT EXISTS plan_interval          TEXT NOT NULL DEFAULT 'monthly'
    CHECK (plan_interval IN ('monthly', 'annual'));


-- ── 20260101000040_subscription_cancel_at.sql ───────────────────────────────────
-- Migration 040: subscription_cancel_at for cancel-at-period-end state
ALTER TABLE firms ADD COLUMN IF NOT EXISTS subscription_cancel_at TIMESTAMPTZ;


-- ── 20260101000041_firm_trial.sql ───────────────────────────────────
-- Migration 041 — Firm trial access
-- trial_ends_at: null = not on trial; set to future date = active trial
-- trial_plan: which plan level during trial (default growth)
-- Standard trial = 7 days; special partners can be extended manually via SQL or admin endpoint.

ALTER TABLE firms
    ADD COLUMN IF NOT EXISTS trial_ends_at  TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS trial_plan     TEXT DEFAULT 'growth'
                                            CHECK (trial_plan IN ('starter', 'growth', 'scale'));

COMMENT ON COLUMN firms.trial_ends_at IS 'Trial expiry timestamp. NULL = not on trial. Set to future date to grant/extend trial.';
COMMENT ON COLUMN firms.trial_plan IS 'Plan level active during trial period (starter/growth/scale). Default growth.';


-- ── 20260101000042_file_size_bytes.sql ───────────────────────────────────
-- Migration 042: file_size_bytes — track uploaded file sizes for storage quota enforcement

-- Pipeline files (bank statements, workpapers, BAS reports)
ALTER TABLE files
    ADD COLUMN IF NOT EXISTS file_size_bytes BIGINT;

-- Supporting evidence and client query documents
ALTER TABLE case_documents
    ADD COLUMN IF NOT EXISTS file_size_bytes BIGINT;

COMMENT ON COLUMN files.file_size_bytes IS 'Raw file size in bytes at upload time. NULL for agent-generated files promoted from extraction.';
COMMENT ON COLUMN case_documents.file_size_bytes IS 'Raw file size in bytes at upload time.';


-- ── 20260101000043_fix_function_search_path.sql ───────────────────────────────────
-- Migration 043: Fix Function Search Path Mutable security warnings
--
-- Supabase Security Advisor flags functions without a fixed search_path.
-- Without SET search_path, a malicious DB user could inject a schema earlier
-- in the path and shadow public objects. Fix: pin all functions to public.
--
-- Uses ALTER FUNCTION to avoid re-writing function bodies.
-- rls_auto_enable is a Supabase internal; revoke public execute access.

-- ── Trigger functions (no parameters) ────────────────────────────────────────
ALTER FUNCTION public.set_updated_at()              SET search_path = public;
ALTER FUNCTION public.set_case_derived_fields()     SET search_path = public;
ALTER FUNCTION public.set_file_firm_id()            SET search_path = public;
ALTER FUNCTION public.prevent_file_state_update()   SET search_path = public;
ALTER FUNCTION public.set_task_derived_fields()     SET search_path = public;
ALTER FUNCTION public.prevent_case_log_mutation()   SET search_path = public;
ALTER FUNCTION public.set_client_firm_id()          SET search_path = public;

-- ── Validation / helper functions ────────────────────────────────────────────
ALTER FUNCTION public.validate_approval_chain(JSONB)  SET search_path = public;
ALTER FUNCTION public.is_mvp_active_case_type(TEXT)   SET search_path = public;

-- ── RLS JWT helper functions ──────────────────────────────────────────────────
ALTER FUNCTION public.auth_firm_id()    SET search_path = public;
ALTER FUNCTION public.auth_team_id()    SET search_path = public;
ALTER FUNCTION public.auth_user_role()  SET search_path = public;

-- ── Service-role RPCs ─────────────────────────────────────────────────────────
ALTER FUNCTION public.test_cleanup_firms(uuid[])          SET search_path = public;
ALTER FUNCTION public.increment_firm_extractions(UUID)    SET search_path = public;

-- ── rls_auto_enable: Supabase internal — revoke public execute ────────────────
-- This function is created by Supabase and uses SECURITY DEFINER.
-- Regular users should never call it directly.
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable() FROM PUBLIC;


-- ── 20260101000044_rls_app_metadata.sql ───────────────────────────────────
-- Migration 044: Read JWT claims from app_metadata (no hook dependency)
--
-- app_metadata is always present in Supabase JWT without requiring any hook.
-- custom_access_token_hook (Migration 006) wrote claims at top level.
-- These updated helpers check app_metadata first, fall back to top-level
-- for backwards compatibility with sessions issued before this migration.
--
-- After backfilling all existing users' app_metadata and confirming login
-- works without the hook, the hook can be safely disabled in the dashboard.

CREATE OR REPLACE FUNCTION auth_firm_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = public
AS $$
    SELECT COALESCE(
        (auth.jwt() -> 'app_metadata' ->> 'firm_id')::uuid,
        (auth.jwt() ->> 'firm_id')::uuid
    )
$$;

CREATE OR REPLACE FUNCTION auth_team_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = public
AS $$
    SELECT COALESCE(
        (auth.jwt() -> 'app_metadata' ->> 'team_id')::uuid,
        (auth.jwt() ->> 'team_id')::uuid
    )
$$;

CREATE OR REPLACE FUNCTION auth_user_role() RETURNS text
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path = public
AS $$
    SELECT COALESCE(
        auth.jwt() -> 'app_metadata' ->> 'user_role',
        auth.jwt() ->> 'user_role'
    )
$$;


-- ── 20260101000045_fix_auth_helper_permissions.sql ───────────────────────────────────
-- Migration 045: Fix auth helper function permissions
-- Remove PUBLIC (anon) execute access; grant only to authenticated role.
-- Fixes 3 "Public Can Execute SECURITY DEFINER Function" warnings in Supabase Security Advisor.
-- The 3 "Signed-In Users Can Execute" warnings for the same functions are expected — RLS policies
-- require authenticated users to call these helpers, so those warnings cannot be eliminated.

REVOKE EXECUTE ON FUNCTION public.auth_firm_id() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.auth_team_id() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.auth_user_role() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.auth_firm_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.auth_team_id() TO authenticated;
GRANT EXECUTE ON FUNCTION public.auth_user_role() TO authenticated;


-- ── 20260101000046_auth_helpers_security_invoker.sql ───────────────────────────────────
-- Migration 046: Change auth RLS helpers to SECURITY INVOKER
-- These functions only call auth.jwt() which is accessible to authenticated users.
-- SECURITY INVOKER eliminates the 3 "Signed-In Users Can Execute SECURITY DEFINER"
-- warnings in Supabase Security Advisor without affecting RLS behaviour.

ALTER FUNCTION public.auth_firm_id() SECURITY INVOKER;
ALTER FUNCTION public.auth_team_id() SECURITY INVOKER;
ALTER FUNCTION public.auth_user_role() SECURITY INVOKER;


-- ── 20260101000048_team_modules.sql ───────────────────────────────────
-- Migration 048: team_modules — per-team business module activation
-- Each team activates a subset of the firm's active modules.
-- Constraint: team_modules ⊆ firm_modules (enforced at API layer).
-- Empty team_modules = inherits all firm modules (backward compatible).

CREATE TABLE team_modules (
  team_id      UUID NOT NULL REFERENCES teams(id) ON DELETE CASCADE,
  firm_id      UUID NOT NULL REFERENCES firms(id) ON DELETE CASCADE,
  module_name  TEXT NOT NULL CHECK (
    module_name IN ('bas_gst', 'payroll', 'tax_individual', 'tax_company', 'smsf', 'asic', 'advisory')
  ),
  active       BOOLEAN NOT NULL DEFAULT TRUE,
  activated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  activated_by UUID REFERENCES users(id) ON DELETE SET NULL,
  PRIMARY KEY (team_id, module_name)
);

CREATE INDEX idx_team_modules_team_id ON team_modules(team_id);
CREATE INDEX idx_team_modules_firm_id  ON team_modules(firm_id);

ALTER TABLE team_modules ENABLE ROW LEVEL SECURITY;

-- Firm boundary — RESTRICTIVE, cannot be overridden
CREATE POLICY team_modules_firm_boundary ON team_modules
  AS RESTRICTIVE FOR ALL
  USING (firm_id = auth_firm_id());

-- All authenticated users can read their firm's team_modules
CREATE POLICY team_modules_read ON team_modules
  AS PERMISSIVE FOR SELECT TO authenticated
  USING (firm_id = auth_firm_id());

-- Owner / admin: firm-wide manage
-- Partner: own team only
CREATE POLICY team_modules_manage ON team_modules
  AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (
    auth_user_role() IN ('owner', 'admin')
    OR (auth_user_role() = 'partner' AND team_id = auth_team_id())
  );

CREATE POLICY team_modules_update ON team_modules
  AS PERMISSIVE FOR UPDATE TO authenticated
  USING (
    auth_user_role() IN ('owner', 'admin')
    OR (auth_user_role() = 'partner' AND team_id = auth_team_id())
  );

CREATE POLICY team_modules_delete ON team_modules
  AS PERMISSIVE FOR DELETE TO authenticated
  USING (
    auth_user_role() IN ('owner', 'admin')
    OR (auth_user_role() = 'partner' AND team_id = auth_team_id())
  );


-- ── 20260101000049_partner_groups.sql ───────────────────────────────────
-- Migration 049 — Partner Groups
--
-- Adds parent_team_id to teams, enabling Partner to create N sub-groups
-- within their team (each with its own Manager, Seniors, Juniors, approval chain).
--
-- Hierarchy:
--   Partner Team  (parent_team_id = NULL, created by Admin)
--     └── Group A (parent_team_id = Partner Team ID, created by Partner)
--     └── Group B (parent_team_id = Partner Team ID, created by Partner)
--
-- RLS extension: Partner sees all data in child groups via auth_child_team_ids().
-- Group members see only their group's data (existing team-scoped RLS unchanged).

-- ── Schema ───────────────────────────────────────────────────────────────────

ALTER TABLE teams ADD COLUMN IF NOT EXISTS
    parent_team_id UUID REFERENCES teams(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_teams_parent_team_id ON teams(parent_team_id);

-- ── Helper function ───────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION auth_child_team_ids()
RETURNS UUID[] AS $$
    SELECT COALESCE(
        ARRAY(
            SELECT id FROM teams
            WHERE parent_team_id = auth_team_id()
            AND firm_id = auth_firm_id()
        ),
        ARRAY[]::UUID[]
    )
$$ LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public;

REVOKE EXECUTE ON FUNCTION auth_child_team_ids() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION auth_child_team_ids() TO authenticated;

-- ── teams RLS — Partner can see and manage their groups ───────────────────────

CREATE POLICY teams_select_partner_groups ON teams
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() = 'partner'
        AND parent_team_id = auth_team_id()
    );

-- Allow Partner to create groups (child teams with parent_team_id = own team)
DROP POLICY IF EXISTS teams_insert ON teams;
CREATE POLICY teams_insert ON teams
    AS PERMISSIVE FOR INSERT
    WITH CHECK (
        auth_user_role() = 'admin'
        OR (
            auth_user_role() = 'partner'
            AND parent_team_id = auth_team_id()
            AND firm_id = auth_firm_id()
        )
    );

-- Allow Partner to update their groups (rename, approval chain)
DROP POLICY IF EXISTS teams_update ON teams;
CREATE POLICY teams_update ON teams
    AS PERMISSIVE FOR UPDATE
    USING (
        auth_user_role() = 'admin'
        OR (id = auth_team_id() AND auth_user_role() IN ('partner', 'manager'))
        OR (parent_team_id = auth_team_id() AND auth_user_role() = 'partner')
    )
    WITH CHECK (
        auth_user_role() = 'admin'
        OR (id = auth_team_id() AND auth_user_role() IN ('partner', 'manager'))
        OR (parent_team_id = auth_team_id() AND auth_user_role() = 'partner')
    );

-- ── users ─────────────────────────────────────────────────────────────────────

CREATE POLICY users_select_partner_groups ON users
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() = 'partner'
        AND team_id = ANY(auth_child_team_ids())
    );

-- ── clients ───────────────────────────────────────────────────────────────────

CREATE POLICY clients_select_partner_groups ON clients
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() = 'partner'
        AND team_id = ANY(auth_child_team_ids())
    );

-- ── directors ─────────────────────────────────────────────────────────────────

CREATE POLICY directors_select_partner_groups ON directors
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() = 'partner'
        AND EXISTS (
            SELECT 1 FROM clients c
            WHERE c.id = directors.client_id
            AND c.team_id = ANY(auth_child_team_ids())
        )
    );

-- ── cases ─────────────────────────────────────────────────────────────────────

CREATE POLICY cases_select_partner_groups ON cases
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() = 'partner'
        AND team_id = ANY(auth_child_team_ids())
    );

-- ── files ─────────────────────────────────────────────────────────────────────

CREATE POLICY files_select_partner_groups ON files
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() = 'partner'
        AND EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = files.case_id
            AND c.team_id = ANY(auth_child_team_ids())
        )
    );

-- ── tasks ─────────────────────────────────────────────────────────────────────

CREATE POLICY tasks_select_partner_groups ON tasks
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() = 'partner'
        AND EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = tasks.case_id
            AND c.team_id = ANY(auth_child_team_ids())
        )
    );

-- ── task_edits ────────────────────────────────────────────────────────────────

CREATE POLICY task_edits_select_partner_groups ON task_edits
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() = 'partner'
        AND EXISTS (
            SELECT 1 FROM tasks t
            JOIN cases c ON c.id = t.case_id
            WHERE t.id = task_edits.task_id
            AND c.team_id = ANY(auth_child_team_ids())
        )
    );

-- ── case_log ──────────────────────────────────────────────────────────────────

CREATE POLICY case_log_select_partner_groups ON case_log
    AS PERMISSIVE FOR SELECT
    USING (
        auth_user_role() = 'partner'
        AND EXISTS (
            SELECT 1 FROM cases c
            WHERE c.id = case_log.case_id
            AND c.team_id = ANY(auth_child_team_ids())
        )
    );


-- ── 20260101000050_cases_created_by.sql ───────────────────────────────────
-- Migration 050: Add created_by to cases table
ALTER TABLE cases ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id);


-- ── 20260101000051_subscription_status.sql ───────────────────────────────────
-- Migration 051: subscription_status column for cancelled firms
-- Replaces the pattern of reverting to 'starter' on subscription deletion.
-- Cancelled firms: data preserved, access locked until reactivation.

ALTER TABLE firms
  ADD COLUMN IF NOT EXISTS subscription_status TEXT
    CHECK (subscription_status IN ('active', 'trialing', 'cancelled'))
    DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ;

-- All existing firms with a stripe_subscription_id are active
UPDATE firms SET subscription_status = 'active' WHERE subscription_status IS NULL;


-- ── 20260101000052_mcp_customers_details.sql ───────────────────────────────────
-- Migration 052: Add firm details to mcp_customers
-- abn, address, contact_person are now required fields on the enterprise request form

ALTER TABLE mcp_customers
  ADD COLUMN IF NOT EXISTS abn TEXT,
  ADD COLUMN IF NOT EXISTS address TEXT,
  ADD COLUMN IF NOT EXISTS contact_person TEXT;


-- ── 20260101000055_mcp_enterprise.sql ───────────────────────────────────
-- Migration 052: MCP Enterprise — self-hosted customer tables
-- mcp_customers: one record per self-hosted deployment
-- mcp_subscriptions: their MCP API access plan (monthly/annual)
-- mcp_api_keys: the actual bearer keys used to call /mcp/* endpoints

-- ─── mcp_customers ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS mcp_customers (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email                   TEXT UNIQUE NOT NULL,
    firm_name               TEXT NOT NULL,
    stripe_customer_id      TEXT,

    -- License (download access gate)
    license_issued_at       TIMESTAMPTZ,
    license_is_free         BOOLEAN DEFAULT FALSE,
    license_payment_intent  TEXT,   -- null for free-tier licenses

    created_at              TIMESTAMPTZ DEFAULT NOW(),
    updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE TRIGGER trg_mcp_customers_updated_at
    BEFORE UPDATE ON mcp_customers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─── mcp_subscriptions ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS mcp_subscriptions (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id             UUID NOT NULL REFERENCES mcp_customers(id) ON DELETE CASCADE,
    stripe_subscription_id  TEXT,
    plan                    TEXT NOT NULL CHECK (plan IN ('trial', 'starter', 'growth', 'scale')),
    interval                TEXT NOT NULL CHECK (interval IN ('monthly', 'annual')),
    runs_per_period         INTEGER NOT NULL,
    runs_used               INTEGER NOT NULL DEFAULT 0,
    period_reset_at         TIMESTAMPTZ,
    status                  TEXT NOT NULL DEFAULT 'active'
                                CHECK (status IN ('active', 'cancelled', 'past_due', 'trialing')),
    cancel_at               TIMESTAMPTZ,
    created_at              TIMESTAMPTZ DEFAULT NOW(),
    updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE TRIGGER trg_mcp_subscriptions_updated_at
    BEFORE UPDATE ON mcp_subscriptions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ─── mcp_api_keys ────────────────────────────────────────────────────────────
-- key_prefix: first 12 chars shown to customer (e.g. "sk-swp-a1b2c")
-- key_hash:   SHA256 of full key, used for server-side validation
CREATE TABLE IF NOT EXISTS mcp_api_keys (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id     UUID NOT NULL REFERENCES mcp_customers(id) ON DELETE CASCADE,
    subscription_id UUID REFERENCES mcp_subscriptions(id) ON DELETE SET NULL,
    key_prefix      TEXT NOT NULL,
    key_hash        TEXT NOT NULL UNIQUE,
    label           TEXT NOT NULL DEFAULT 'Default',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    last_used_at    TIMESTAMPTZ,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ─── Indexes ─────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_mcp_subscriptions_customer
    ON mcp_subscriptions(customer_id);

CREATE INDEX IF NOT EXISTS idx_mcp_api_keys_customer
    ON mcp_api_keys(customer_id);

-- key_hash lookup is the hot path for every MCP request
CREATE INDEX IF NOT EXISTS idx_mcp_api_keys_hash
    ON mcp_api_keys(key_hash) WHERE is_active = TRUE;

-- ─── RLS ─────────────────────────────────────────────────────────────────────
-- MCP customers are NOT Supabase Auth users.
-- All access from backend uses service_role (bypasses RLS).
-- RLS enabled with no PERMISSIVE policies = anon/authenticated cannot read.
ALTER TABLE mcp_customers    ENABLE ROW LEVEL SECURITY;
ALTER TABLE mcp_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE mcp_api_keys     ENABLE ROW LEVEL SECURITY;

-- ─── Free license counter helper ─────────────────────────────────────────────
-- Count via: SELECT COUNT(*) FROM mcp_customers WHERE license_is_free = TRUE
-- Limit configured here as a constant (change when promotion ends)
CREATE OR REPLACE FUNCTION mcp_free_licenses_remaining()
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = public
AS $$
    SELECT GREATEST(0, 50 - COUNT(*)::int)
    FROM mcp_customers
    WHERE license_is_free = TRUE AND license_issued_at IS NOT NULL;
$$;


-- ── 20260101000056_mcp_topup_credits.sql ───────────────────────────────────
-- Migration 053: Add topup_credits to mcp_subscriptions
-- Topup credits are purchased separately and never expire across billing periods.
-- runs_per_period = base plan quota (resets monthly)
-- topup_credits   = purchased top-up (never zeroed on reset)
-- Quota gate: runs_used >= runs_per_period + topup_credits → blocked

ALTER TABLE mcp_subscriptions
    ADD COLUMN IF NOT EXISTS topup_credits INTEGER NOT NULL DEFAULT 0;


-- ── 20260101000057_license_installations.sql ───────────────────────────────────
-- Migration 053: license_installations table
-- Tracks which installation_id is bound to which MCP subscription.
-- Phase 1: records bindings for audit; instance-count enforcement deferred to Phase 2.
-- Accessible only via service_role (admin client); RLS blocks all user access.

CREATE TABLE IF NOT EXISTS license_installations (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id     UUID        NOT NULL REFERENCES mcp_customers(id)     ON DELETE CASCADE,
    subscription_id UUID        NOT NULL REFERENCES mcp_subscriptions(id) ON DELETE CASCADE,
    installation_id UUID        NOT NULL,
    hostname        TEXT,
    activated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_heartbeat  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    CONSTRAINT uq_license_inst UNIQUE (subscription_id, installation_id)
);

-- Index for fast lookup by subscription
CREATE INDEX IF NOT EXISTS idx_license_inst_sub ON license_installations(subscription_id);

-- RLS: deny all user access — only service_role (admin client) may read/write
ALTER TABLE license_installations ENABLE ROW LEVEL SECURITY;
CREATE POLICY license_installations_deny_users ON license_installations
    AS RESTRICTIVE FOR ALL
    USING (FALSE);


-- ── 20260101000058_cases_soft_delete.sql ───────────────────────────────────
-- Migration 058: Soft delete for cases + unique constraint on active folders
-- Prevents duplicate folders for same client+type+period
-- Allows "delete" without triggering case_log append-only trigger

ALTER TABLE cases ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Only one active (non-deleted) folder per client + type + period
CREATE UNIQUE INDEX IF NOT EXISTS idx_cases_client_type_period_active
  ON cases (client_id, case_type, period)
  WHERE deleted_at IS NULL;


-- ── 20260101000059_task_status_semantic.sql ───────────────────────────────────
-- Migration 011: Semantic task status values
--
-- Replace generic 'approved' with role-specific terminal statuses:
--   validated  → validate_extraction / validate_gst submitted by Junior/Senior
--   reviewed   → senior_review submitted by Senior
--   confirmed  → client_confirm submitted by Partner
--   certified  → certify submitted by Partner
--   approved   → manager_approve submitted by Manager (kept — manager IS approving)
--
-- 'approved' is retained in the enum for manager_approve tasks and as a fallback.

-- 1. Drop existing CHECK constraint on status
ALTER TABLE tasks DROP CONSTRAINT IF EXISTS tasks_status_check;

-- 2. Add new CHECK constraint with semantic values
ALTER TABLE tasks
    ADD CONSTRAINT tasks_status_check
    CHECK (status IN (
        'pending',
        'in_progress',
        'waiting_human',
        'validated',
        'reviewed',
        'confirmed',
        'certified',
        'approved',
        'rejected',
        'complete'
    ));

-- 3. Drop and recreate completed_at consistency constraint
ALTER TABLE tasks DROP CONSTRAINT IF EXISTS chk_completed_at_consistency;

ALTER TABLE tasks
    ADD CONSTRAINT chk_completed_at_consistency
    CHECK (
        (status IN ('validated', 'reviewed', 'confirmed', 'certified', 'approved', 'rejected', 'complete')
            AND completed_at IS NOT NULL)
        OR status NOT IN ('validated', 'reviewed', 'confirmed', 'certified', 'approved', 'rejected', 'complete')
    );


-- ── 20260101000060_client_xero_qbo_tenant.sql ───────────────────────────────────
-- Migration 060: Per-client Xero and QBO tenant mapping
-- Accounting firms push BAS to each CLIENT's own Xero/QBO org,
-- not the firm's own account. These columns store the per-client mapping.
-- Fallback: if NULL, push falls back to firm-level selected tenant.

ALTER TABLE clients
  ADD COLUMN IF NOT EXISTS xero_tenant_id   TEXT,
  ADD COLUMN IF NOT EXISTS xero_tenant_name TEXT,
  ADD COLUMN IF NOT EXISTS qbo_realm_id     TEXT,
  ADD COLUMN IF NOT EXISTS qbo_company_name TEXT;


-- ── 20260101000061_cases_push_timestamps.sql ───────────────────────────────────
-- Migration 061: Track when BAS journals were pushed to accounting software
-- Prevents duplicate pushes by persisting push state across page navigations.

ALTER TABLE cases
  ADD COLUMN IF NOT EXISTS xero_pushed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS qbo_pushed_at  TIMESTAMPTZ;


-- ── 20260101000062_mcp_allowed_origin.sql ───────────────────────────────────
-- Migration 062: add allowed_origin to mcp_customers
-- Self-hosted customers register their deployment domain here.
-- The gateway service checks this field for dynamic CORS authorisation.

ALTER TABLE mcp_customers
  ADD COLUMN IF NOT EXISTS allowed_origin TEXT;

COMMENT ON COLUMN mcp_customers.allowed_origin IS
  'Self-hosted deployment URL (e.g. https://sweeper.firmname.com.au). Used by gateway for CORS authorisation.';


-- ── 20260101000062_mcp_pages_quota.sql ───────────────────────────────────
-- Migration 062: Add pages_used and pages_limit to mcp_subscriptions
-- pages_used: running count of PDF pages processed this billing period
-- pages_limit: monthly page cap (NULL = no cap; trial = 35; paid plans = from _MCP_PLAN_PAGES)

ALTER TABLE mcp_subscriptions
  ADD COLUMN IF NOT EXISTS pages_used  INTEGER NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS pages_limit INTEGER DEFAULT NULL;


-- ── 20260101000062_users_update_rls_child_group.sql ───────────────────────────────────
-- Fix users_update WITH CHECK to allow Partner/Manager to move members into child groups.
-- USING checks the OLD row (source team_id must match caller's team) — unchanged.
-- WITH CHECK previously required new team_id = auth_team_id(), blocking moves to groups.
-- New WITH CHECK also accepts new team_id that is a child group of auth_team_id().

DROP POLICY IF EXISTS users_update ON users;

CREATE POLICY users_update ON users
    AS PERMISSIVE FOR UPDATE
    USING (
        id = auth.uid()
        OR auth_user_role() = 'admin'
        OR (team_id = auth_team_id()
            AND auth_user_role() IN ('partner', 'manager'))
    )
    WITH CHECK (
        id = auth.uid()
        OR auth_user_role() = 'admin'
        OR (
            auth_user_role() IN ('partner', 'manager')
            AND (
                team_id = auth_team_id()
                OR EXISTS (
                    SELECT 1 FROM teams t
                    WHERE t.id = users.team_id
                      AND t.parent_team_id = auth_team_id()
                )
            )
        )
    );


-- ── 20260101000063_selfhosted_query_anon.sql ───────────────────────────────────
-- Migration 063: self-hosted client query anonymous access
-- Creates SECURITY DEFINER functions so the ClientQueryPage can work
-- with the Supabase anon key (no backend server required).
-- Required for self-hosted deployments; SaaS uses the backend API instead.
-- Apply via Supabase SQL Editor.

-- ─── Verify token + return case context ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_query_link_by_token(
  p_token    TEXT,
  p_password TEXT
)
RETURNS TABLE (
  link_id       UUID,
  case_id       UUID,
  submitted_at  TIMESTAMPTZ,
  business_name TEXT,
  period        TEXT
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT
    ql.id            AS link_id,
    ql.case_id,
    ql.submitted_at,
    cl.business_name,
    ca.period
  FROM client_query_links ql
  JOIN cases   ca ON ca.id = ql.case_id
  JOIN clients cl ON cl.id = ca.client_id
  WHERE ql.token    = p_token
    AND ql.password = p_password
    AND ql.expires_at > NOW();
$$;

GRANT EXECUTE ON FUNCTION public.get_query_link_by_token(TEXT, TEXT) TO anon, authenticated;

-- ─── Get queries for a verified link ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_queries_by_link(
  p_link_id  UUID,
  p_token    TEXT,
  p_password TEXT
)
RETURNS TABLE (
  id                  UUID,
  transaction_row_ref TEXT,
  merchant            TEXT,
  amount              TEXT,
  query_text          TEXT,
  context_note        TEXT,
  client_answer       TEXT,
  status              TEXT,
  date                TEXT,
  description         TEXT,
  account             TEXT
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT
    q.id,
    q.transaction_row_ref,
    q.merchant,
    q.amount,
    q.query_text,
    q.context_note,
    q.client_answer,
    q.status,
    q.date,
    q.description,
    q.account
  FROM queries q
  JOIN client_query_links ql ON ql.id = q.link_id
  WHERE q.link_id   = p_link_id
    AND ql.token    = p_token
    AND ql.password = p_password
    AND ql.expires_at > NOW();
$$;

GRANT EXECUTE ON FUNCTION public.get_queries_by_link(UUID, TEXT, TEXT) TO anon, authenticated;

-- ─── Submit client query answers ──────────────────────────────────────────────
-- p_answers: [{ "query_id": "uuid", "client_answer": "text" }, ...]
CREATE OR REPLACE FUNCTION public.submit_client_query_answers(
  p_token    TEXT,
  p_password TEXT,
  p_answers  JSONB
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_link client_query_links%ROWTYPE;
BEGIN
  SELECT * INTO v_link
  FROM client_query_links
  WHERE token      = p_token
    AND password   = p_password
    AND expires_at > NOW()
    AND submitted_at IS NULL;

  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;

  UPDATE queries AS q SET
    client_answer = src.a->>'client_answer',
    status        = 'answered',
    answered_at   = NOW()
  FROM (SELECT jsonb_array_elements(p_answers) AS a) AS src
  WHERE q.id      = (src.a->>'query_id')::UUID
    AND q.link_id = v_link.id;

  UPDATE client_query_links SET submitted_at = NOW() WHERE id = v_link.id;

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.submit_client_query_answers(TEXT, TEXT, JSONB) TO anon;


-- ── 20260101000063_users_insert_policy.sql ───────────────────────────────────
-- Allow owner/admin to insert new users within their own firm.
-- Required for self-hosted Add Member flow (direct Supabase, no backend).
-- firm_boundary RESTRICTIVE policy still enforces firm isolation.
CREATE POLICY users_owner_admin_insert ON public.users
  AS PERMISSIVE FOR INSERT
  TO authenticated
  WITH CHECK (
    firm_id = auth_firm_id()
    AND auth_user_role() IN ('owner', 'admin')
  );


-- ── 20260101000064_teams_insert_policy.sql ───────────────────────────────────
-- Allow owner/admin to create new teams within their own firm.
-- Required for self-hosted Partner creation (direct Supabase, no backend).
CREATE POLICY teams_owner_admin_insert ON public.teams
  AS PERMISSIVE FOR INSERT
  TO authenticated
  WITH CHECK (
    firm_id = auth_firm_id()
    AND auth_user_role() IN ('owner', 'admin')
  );


-- ── 20260101000065_delete_client_query_document.sql ───────────────────────────────────
-- Migration 065: RPC for client to delete their own uploaded document
-- Public endpoint (anon key) — SECURITY DEFINER to bypass RLS
-- Validates token + password + document ownership before deleting

CREATE OR REPLACE FUNCTION public.delete_client_query_document(
  p_token      TEXT,
  p_password   TEXT,
  p_doc_id     UUID
) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_link  client_query_links%ROWTYPE;
  v_count INT;
BEGIN
  -- Validate token + password (link must be active, not submitted)
  SELECT * INTO v_link
  FROM client_query_links
  WHERE token = p_token
    AND submitted_at IS NULL
    AND expires_at > NOW();
  IF NOT FOUND THEN RETURN FALSE; END IF;
  IF v_link.password != p_password THEN RETURN FALSE; END IF;

  -- Verify document belongs to a query in this link
  SELECT COUNT(*) INTO v_count
  FROM case_documents cd
  JOIN queries q ON cd.query_id = q.id
  WHERE cd.id = p_doc_id
    AND q.link_id = v_link.id;
  IF v_count = 0 THEN RETURN FALSE; END IF;

  -- Delete the document record
  DELETE FROM case_documents WHERE id = p_doc_id;
  RETURN TRUE;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_client_query_document(TEXT, TEXT, UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.delete_client_query_document(TEXT, TEXT, UUID) TO anon, authenticated;


-- ── 20260101000066_selfhosted_client_upload.sql ───────────────────────────────────
-- Migration 066: self-hosted client query evidence upload RPC
-- Records client-uploaded evidence in case_documents after validating the token.
-- Called from ClientQueryPage in self-hosted mode (anon key, no backend server).
-- The physical file is uploaded directly to the 'client-uploads' Storage bucket by the
-- frontend using the Supabase anon key; this function records the case_documents metadata.
--
-- Setup required in Supabase Dashboard → Storage:
--   Create bucket: client-uploads (private)
--   Add policy:  INSERT to anon — no restrictions (token validation is in this function)
--   Add policy:  SELECT to anon — WHERE name LIKE '{token}/%' (token-scoped read for deletion)

CREATE OR REPLACE FUNCTION public.record_client_query_upload(
  p_token        TEXT,
  p_password     TEXT,
  p_query_id     UUID,
  p_file_name    TEXT,
  p_storage_path TEXT
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_link   client_query_links%ROWTYPE;
  v_firm_id UUID;
  v_doc_id  UUID;
BEGIN
  -- Validate token + password (must be active, not expired)
  SELECT * INTO v_link
  FROM client_query_links
  WHERE token      = p_token
    AND password   = p_password
    AND expires_at > NOW();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid token or link expired';
  END IF;

  -- Verify query belongs to this link
  IF NOT EXISTS (
    SELECT 1 FROM queries WHERE id = p_query_id AND link_id = v_link.id
  ) THEN
    RAISE EXCEPTION 'Query not found for this link';
  END IF;

  -- Get firm_id from the case
  SELECT firm_id INTO v_firm_id FROM cases WHERE id = v_link.case_id;

  -- Insert document record (uploaded_by intentionally NULL — client has no user account)
  INSERT INTO case_documents (
    case_id, firm_id, query_id, document_type, file_name, storage_path, note
  ) VALUES (
    v_link.case_id, v_firm_id, p_query_id, 'client_upload', p_file_name, p_storage_path,
    'Uploaded by client'
  )
  RETURNING id INTO v_doc_id;

  RETURN v_doc_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.record_client_query_upload(TEXT, TEXT, UUID, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.record_client_query_upload(TEXT, TEXT, UUID, TEXT, TEXT) TO anon, authenticated;

