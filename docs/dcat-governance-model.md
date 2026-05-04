# DCAT 3 governance model

How DGT-next models its catalog and how that model is used to govern datasets
that OpenMetadata ingests.

The schema lives in two PostgreSQL schemas inside the `governance_catalog`
database, both created at first start by `governance/init/00_dcat_schema.sql`:

- **`dcat`** — the W3C Data Catalog Vocabulary 3 core. Standards-aligned,
  intentionally minimal; this is what travels well to other catalogs and to
  `data.gov`-style portals.
- **`gov`** — the DGT governance overlay. RACI roles, policies, permissible
  uses, and security markings derived from the *DGT Policy Draft v0.3*.

A pair of consumption views (`dcat.vw_catalog_dataset`,
`gov.vw_resource_governance`) flatten the model for OpenMetadata ingestion;
they're what the OM UI surfaces to stewards and stakeholders.

---

## The `dcat` schema (DCAT 3 core)

```
catalog                 dcat:Catalog
  └── resource          dcat:Dataset / dcat:DataService / dcat:DatasetSeries
        ├── distribution     dcat:Distribution
        └── resource_concept ↔ concept (skos:Concept)   themes / keywords

agent                   foaf:Agent     (publisher, creator, contact)
```

| Table | DCAT class | Carries |
|-------|------------|---------|
| `dcat.catalog` | `dcat:Catalog` | A named collection of resources (e.g., "DGT Demo Catalog"). |
| `dcat.resource` | `dcat:Resource` (Dataset/DataService/DatasetSeries via discriminator) | The dataset itself: title, description, identifier, license, access rights, temporal/spatial coverage, links to publisher and creator. |
| `dcat.distribution` | `dcat:Distribution` | A specific representation: format, media type, byte size, checksum, download URL. One resource → many distributions. |
| `dcat.agent` | `foaf:Agent` | People or organizations referenced as publishers, creators, or contact points. |
| `dcat.concept` | `skos:Concept` | Controlled-vocabulary terms grouped by `scheme` (themes, keywords). |
| `dcat.resource_concept` | n-ary | Joins resources to concepts with a role discriminator (`theme` vs `keyword`). |

This is roughly the minimum a DCAT 3 catalog needs to be syntactically
compliant. It's intentionally light on optional properties — those land in
later iterations when stakeholder use-cases pin them down.

---

## The `gov` overlay

DCAT describes *what* a resource is. The `gov` schema describes *how it is
governed* — who's accountable, what uses are permitted, what classification
applies.

| Table | Mirrors | Purpose |
|-------|---------|---------|
| `gov.governance_role` | RACI roles in the policy draft | Program Data Owner, Program DBA, Data Steward, Data Custodian, IT Liaison, plus any agency-specific roles. Authority level (`enterprise` / `program` / `dataset`). |
| `gov.role_assignment` | the actual filling of a seat | Joins a `governance_role` to a `dcat.agent` (a person or org), optionally scoped to a single `dcat.resource`. Carries start/end dates so historical assignments are queryable. |
| `gov.policy` | external authority | Named policy with `policy_type` ∈ {privacy, cybersecurity, sharing, retention, quality}, an authority (e.g., "Privacy Act"), and a review cycle in days. |
| `gov.permissible_use` | "what you can do with this data" | Use case + approval requirements, attached to a parent policy. |
| `gov.resource_permissible_use` | the join | Which uses are actually approved for which resource, with free-text conditions. |
| `gov.security_marking` | classification taxonomy | Public / Internal / Restricted-PII / etc., with a classification level. |
| `gov.resource_security_marking` | the join | Marks a resource with one or more security tags, who assigned it and when, and the rationale. |
| `gov.decision_log` | audit trail (placeholder) | One row per governance decision (publish, deprecate, restrict). API to populate this is future work. |

The overlay is opinionated about three things:

1. **Roles and policies are first-class entities**, not free-text fields on a
   dataset. A new policy adds rows to `gov.policy` and `gov.permissible_use`;
   it doesn't require schema changes.
2. **Stewardship is per-resource and per-time-window** via
   `gov.role_assignment`. "Who is responsible for the CLUE dataset right now"
   is a query, not a guess.
3. **Security markings are multi-valued**. A dataset can be Internal *and*
   Restricted-PII; the catalog reflects that without losing detail.

---

## How an ingested dataset becomes governed

This is the lifecycle for a dataset entering the catalog. Each step is a
distinct, auditable action.

### Step 1: OM ingests the table

`make ingest` (or the `dgt_clue_ingestion` Airflow DAG) runs the
`metadata ingest` workflow against `governance_pg`. OM creates table entities
under the `dgt-governance` Database Service for everything matching the
`schemaFilterPattern` — so `clue.cases`, `clue.defendants`, etc. all become
OpenMetadata `Table` entities with their column schemas.

At this point the dataset is **discoverable but ungoverned**: no DCAT
metadata, no policies, no steward.

### Step 2: A steward registers it as a DCAT resource

A Data Steward (per the RACI role) inserts a row into `dcat.resource`
pointing at the same logical dataset:

```sql
INSERT INTO dcat.resource (
    catalog_id, resource_type, identifier, title, description,
    keywords, themes, publisher_id, license, access_rights, ...
)
VALUES (
    (SELECT catalog_id FROM dcat.catalog WHERE title = 'DGT Demo Catalog'),
    'Dataset',
    'https://mdcourts.gov/clue/allegany',
    'Maryland Allegany County Civil Court Cases',
    'Court case intake records for civil matters in Allegany County.',
    ARRAY['court records', 'civil cases', 'maryland'],
    ARRAY['Justice'],
    (SELECT agent_id FROM dcat.agent WHERE name = 'Maryland Judiciary'),
    'CC-BY-4.0',
    'public', ...
);
```

The `identifier` column is the DCAT identity — typically a URI or a Data.gov
package id. `clue.cases` is the *Postgres* table; `dcat.resource` is the
*catalog* entry that describes it.

### Step 3: Governance attachments

The same steward attaches policies, roles, and security markings:

```sql
-- Privacy policy applies (the seeded "Default Privacy Policy")
INSERT INTO gov.resource_permissible_use (resource_id, use_id, conditions)
SELECT r.resource_id, p.use_id, 'Aggregated reporting only'
FROM dcat.resource r, gov.permissible_use p
WHERE r.title = 'Maryland Allegany County Civil Court Cases'
  AND p.use_case = 'Public statistical reporting';

-- Mark sensitive (auto-classification flagged PII columns; the steward
-- formalizes that with a security marking)
INSERT INTO gov.resource_security_marking (resource_id, marking_id, rationale)
SELECT r.resource_id, s.marking_id,
       'Contains defendant and plaintiff names'
FROM dcat.resource r, gov.security_marking s
WHERE r.title = 'Maryland Allegany County Civil Court Cases'
  AND s.name = 'Restricted-PII';

-- Assign a Program Data Owner
INSERT INTO gov.role_assignment (role_id, agent_id, resource_id, start_date)
SELECT gr.role_id, a.agent_id, r.resource_id, CURRENT_DATE
FROM gov.governance_role gr, dcat.agent a, dcat.resource r
WHERE gr.name = 'Program Data Owner'
  AND a.name = 'Maryland Judiciary'
  AND r.title = 'Maryland Allegany County Civil Court Cases';
```

This is the "human" governance layer. Most of these inserts will eventually
be driven by a UI / API rather than hand-written SQL, but the schema is
deliberately CRUD-friendly so that a thin web form is enough.

### Step 4: The catalog re-ingests, and OM surfaces the governance context

Re-running `make ingest` causes OM to re-read `dcat.vw_catalog_dataset` and
`gov.vw_resource_governance`. Those views flatten the model:

```sql
-- dcat.vw_catalog_dataset: every dcat.resource of type 'Dataset' joined
-- to its publisher and parent catalog
SELECT
  r.resource_id, r.identifier, r.title, r.description, r.keywords,
  r.themes, pub.name AS publisher, r.license, r.access_rights,
  r.issued, r.modified, c.title AS catalog
FROM dcat.resource r
LEFT JOIN dcat.agent pub ON pub.agent_id = r.publisher_id
LEFT JOIN dcat.catalog c ON c.catalog_id = r.catalog_id
WHERE r.resource_type = 'Dataset';

-- gov.vw_resource_governance: roles, permissible uses, and markings
-- aggregated per resource
SELECT
  r.resource_id, r.title,
  array_agg(DISTINCT gr.name) AS roles,
  array_agg(DISTINCT pu.use_case) AS permissible_uses,
  array_agg(DISTINCT sm.name) AS security_markings
FROM dcat.resource r
LEFT JOIN gov.role_assignment ra ON ra.resource_id = r.resource_id
LEFT JOIN gov.governance_role gr ON gr.role_id = ra.role_id
LEFT JOIN gov.resource_permissible_use rpu ON rpu.resource_id = r.resource_id
LEFT JOIN gov.permissible_use pu ON pu.use_id = rpu.use_id
LEFT JOIN gov.resource_security_marking rsm ON rsm.resource_id = r.resource_id
LEFT JOIN gov.security_marking sm ON sm.marking_id = rsm.marking_id
GROUP BY r.resource_id, r.title;
```

OM ingests these views as if they were tables, so a stakeholder browsing
`dgt-governance.governance_catalog.gov.vw_resource_governance` in the OM UI
sees a row per governed resource with arrays of roles, permitted uses, and
security tags.

### Step 5: Auto Classification reinforces the markings

`make classify` runs OM's Auto Classification engine over the dataset's
sample data and tags columns with `PII.Sensitive` / `PII.NonSensitive`. This
is *complementary* to step 3:

- The DCAT/gov layer is the **human-asserted** governance: someone with
  authority decided this dataset is Restricted-PII and signed off.
- Auto Classification is the **machine-asserted** evidence: the ML/regex
  engine independently detected name- and date-shaped data in specific
  columns.

When the two disagree (e.g., classifier flags a column as PII but the dataset
isn't marked Restricted-PII), that's a governance signal — a steward should
review whether the security marking is accurate.

---

## Summary diagram

```
         External authority             People & orgs
       (laws, regulations)             (foaf:Agent)
                │                            │
                ▼                            ▼
        gov.policy ──── gov.permissible_use     dcat.agent
              │                  │                   │
              └─────┐    ┌───────┘                   │
                    ▼    ▼                           ▼
             gov.resource_permissible_use   gov.role_assignment
                          │                          │
                          ▼                          ▼
                ┌───────────────────────────────────────────┐
                │             dcat.resource                 │  ←─── dcat.catalog
                │  (Dataset / DataService / DatasetSeries)  │
                └─────────┬─────────────────────────┬───────┘
                          │                         │
                          ▼                         ▼
                  dcat.distribution      gov.resource_security_marking
                                                    │
                                                    ▼
                                          gov.security_marking
```

`dcat.resource` is the hub: every governance attachment hangs off it, and
every distribution / publication artifact references it.

---

## What this is *not*

- **Not a policy enforcement engine.** The schema records that
  `Restricted-PII` applies to a resource; it doesn't stop a query against
  `clue.cases.name`. Enforcement is the job of the database (RLS / column
  privileges) or a downstream gateway. The catalog's role is to make the
  governance state visible and auditable.
- **Not a perfect DCAT serializer (yet).** Round-tripping to RDF/JSON-LD
  needs a thin export layer — out of scope for the MVP.
- **Not a substitute for OpenMetadata's own glossary.** OM has a Business
  Glossary feature that overlaps with `dcat.concept`. We expose both: DCAT
  concepts for portability across catalogs, OM glossary terms for in-catalog
  navigation. They can be cross-mapped once stakeholders settle on canonical
  vocabularies.
