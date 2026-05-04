-- DGT governance catalog schema (starter)
-- Aligned with DCAT 3 (https://www.w3.org/TR/vocab-dcat-3/) core classes.
-- Governance overlay (roles, permissible use, security marking) layered on top.
--
-- This is an MVP shape — expected to be amended in collaboration with
-- policy stakeholders. Keep it minimal until the policy schema solidifies.

CREATE SCHEMA IF NOT EXISTS dcat;
CREATE SCHEMA IF NOT EXISTS gov;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;
-- Required by OM's lineage + profile workflows (query log parsing).
-- The library is loaded via `shared_preload_libraries` in the compose command.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ---------------------------------------------------------------------------
-- DCAT 3 core
-- ---------------------------------------------------------------------------

-- dcat:Catalog
CREATE TABLE dcat.catalog (
  catalog_id      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  title           TEXT NOT NULL,
  description     TEXT,
  publisher_id    UUID,
  homepage        TEXT,
  language        TEXT,
  issued          TIMESTAMPTZ DEFAULT NOW(),
  modified        TIMESTAMPTZ DEFAULT NOW()
);

-- dcat:Resource ancestor; we collapse Dataset / DataService into one table
-- with a discriminator, mirroring DCAT's Resource hierarchy.
CREATE TABLE dcat.resource (
  resource_id       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  catalog_id        UUID REFERENCES dcat.catalog(catalog_id) ON DELETE SET NULL,
  resource_type     TEXT NOT NULL CHECK (resource_type IN ('Dataset','DataService','DatasetSeries')),
  identifier        TEXT UNIQUE,
  title             TEXT NOT NULL,
  description       TEXT,
  keywords          TEXT[],
  themes            TEXT[],
  publisher_id      UUID,
  creator_id        UUID,
  contact_point     TEXT,
  landing_page      TEXT,
  license           TEXT,
  rights            TEXT,
  access_rights     TEXT,
  issued            TIMESTAMPTZ DEFAULT NOW(),
  modified          TIMESTAMPTZ DEFAULT NOW(),
  temporal_start    TIMESTAMPTZ,
  temporal_end      TIMESTAMPTZ,
  spatial           TEXT
);

-- dcat:Distribution
CREATE TABLE dcat.distribution (
  distribution_id  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  resource_id      UUID NOT NULL REFERENCES dcat.resource(resource_id) ON DELETE CASCADE,
  title            TEXT,
  description      TEXT,
  access_url       TEXT,
  download_url     TEXT,
  media_type       TEXT,
  format           TEXT,
  byte_size        BIGINT,
  conforms_to      TEXT,
  checksum         TEXT,
  issued           TIMESTAMPTZ DEFAULT NOW(),
  modified         TIMESTAMPTZ DEFAULT NOW()
);

-- foaf:Agent (publisher / creator / contact)
CREATE TABLE dcat.agent (
  agent_id     UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name         TEXT NOT NULL,
  agent_type   TEXT CHECK (agent_type IN ('Person','Organization')) DEFAULT 'Organization',
  email        TEXT,
  homepage     TEXT
);

ALTER TABLE dcat.catalog
  ADD CONSTRAINT catalog_publisher_fk FOREIGN KEY (publisher_id) REFERENCES dcat.agent(agent_id);
ALTER TABLE dcat.resource
  ADD CONSTRAINT resource_publisher_fk FOREIGN KEY (publisher_id) REFERENCES dcat.agent(agent_id),
  ADD CONSTRAINT resource_creator_fk   FOREIGN KEY (creator_id)   REFERENCES dcat.agent(agent_id);

-- skos:Concept for themes / keywords
CREATE TABLE dcat.concept (
  concept_id    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  scheme        TEXT NOT NULL,
  pref_label    TEXT NOT NULL,
  alt_labels    TEXT[],
  definition    TEXT,
  UNIQUE (scheme, pref_label)
);

CREATE TABLE dcat.resource_concept (
  resource_id   UUID NOT NULL REFERENCES dcat.resource(resource_id) ON DELETE CASCADE,
  concept_id    UUID NOT NULL REFERENCES dcat.concept(concept_id)   ON DELETE CASCADE,
  role          TEXT NOT NULL CHECK (role IN ('theme','keyword')),
  PRIMARY KEY (resource_id, concept_id, role)
);

-- ---------------------------------------------------------------------------
-- Governance overlay (RACI roles + permissible use + security marking)
-- Mirrors the Policy Draft v0.3 structure, kept as a starter sketch.
-- ---------------------------------------------------------------------------

CREATE TABLE gov.governance_role (
  role_id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name             TEXT UNIQUE NOT NULL,
  description      TEXT,
  authority_level  TEXT CHECK (authority_level IN ('enterprise','program','dataset'))
);

CREATE TABLE gov.role_assignment (
  assignment_id  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  role_id        UUID NOT NULL REFERENCES gov.governance_role(role_id),
  agent_id       UUID NOT NULL REFERENCES dcat.agent(agent_id),
  resource_id    UUID REFERENCES dcat.resource(resource_id), -- nullable = enterprise scope
  start_date     DATE DEFAULT CURRENT_DATE,
  end_date       DATE
);

CREATE TABLE gov.policy (
  policy_id      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name           TEXT NOT NULL,
  policy_type    TEXT CHECK (policy_type IN ('privacy','cybersecurity','sharing','retention','quality')),
  authority      TEXT,
  summary        TEXT,
  effective_date DATE,
  review_cycle_days INTEGER
);

CREATE TABLE gov.permissible_use (
  use_id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  policy_id         UUID REFERENCES gov.policy(policy_id),
  use_case          TEXT NOT NULL,
  description       TEXT,
  requires_approval BOOLEAN DEFAULT FALSE,
  approval_authority TEXT
);

CREATE TABLE gov.resource_permissible_use (
  resource_id      UUID NOT NULL REFERENCES dcat.resource(resource_id) ON DELETE CASCADE,
  use_id           UUID NOT NULL REFERENCES gov.permissible_use(use_id),
  conditions       TEXT,
  PRIMARY KEY (resource_id, use_id)
);

CREATE TABLE gov.security_marking (
  marking_id       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name             TEXT UNIQUE NOT NULL,
  classification_level TEXT,
  description      TEXT
);

CREATE TABLE gov.resource_security_marking (
  resource_id   UUID NOT NULL REFERENCES dcat.resource(resource_id) ON DELETE CASCADE,
  marking_id    UUID NOT NULL REFERENCES gov.security_marking(marking_id),
  assigned_on   TIMESTAMPTZ DEFAULT NOW(),
  rationale     TEXT,
  PRIMARY KEY (resource_id, marking_id)
);

-- Audit / decision log (placeholder — populated by future governance API)
CREATE TABLE gov.decision_log (
  decision_id   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  resource_id   UUID REFERENCES dcat.resource(resource_id),
  decision_type TEXT,
  decision_text TEXT,
  decided_by    UUID REFERENCES dcat.agent(agent_id),
  decided_on    TIMESTAMPTZ DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- Catalog views (consumed by OpenMetadata's database connector)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW dcat.vw_catalog_dataset AS
SELECT
  r.resource_id,
  r.identifier,
  r.title,
  r.description,
  r.keywords,
  r.themes,
  pub.name      AS publisher,
  contact_point,
  r.landing_page,
  r.license,
  r.access_rights,
  r.issued,
  r.modified,
  c.title       AS catalog
FROM dcat.resource r
LEFT JOIN dcat.agent   pub ON pub.agent_id = r.publisher_id
LEFT JOIN dcat.catalog c   ON c.catalog_id = r.catalog_id
WHERE r.resource_type = 'Dataset';

CREATE OR REPLACE VIEW gov.vw_resource_governance AS
SELECT
  r.resource_id,
  r.title,
  COALESCE(array_agg(DISTINCT gr.name) FILTER (WHERE gr.name IS NOT NULL), '{}') AS roles,
  COALESCE(array_agg(DISTINCT pu.use_case) FILTER (WHERE pu.use_case IS NOT NULL), '{}') AS permissible_uses,
  COALESCE(array_agg(DISTINCT sm.name) FILTER (WHERE sm.name IS NOT NULL), '{}') AS security_markings
FROM dcat.resource r
LEFT JOIN gov.role_assignment ra ON ra.resource_id = r.resource_id
LEFT JOIN gov.governance_role gr ON gr.role_id     = ra.role_id
LEFT JOIN gov.resource_permissible_use rpu ON rpu.resource_id = r.resource_id
LEFT JOIN gov.permissible_use pu ON pu.use_id      = rpu.use_id
LEFT JOIN gov.resource_security_marking rsm ON rsm.resource_id = r.resource_id
LEFT JOIN gov.security_marking sm ON sm.marking_id = rsm.marking_id
GROUP BY r.resource_id, r.title;
