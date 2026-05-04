-- Minimal seed data so the catalog is non-empty on first OM ingestion.

INSERT INTO dcat.agent (name, agent_type, email) VALUES
  ('Massive Data Institute', 'Organization', 'mdi@georgetown.edu'),
  ('Maryland Judiciary',     'Organization', 'data@mdcourts.gov')
ON CONFLICT DO NOTHING;

INSERT INTO dcat.catalog (title, description, publisher_id, homepage)
SELECT 'DGT Demo Catalog',
       'Sample DCAT 3 catalog for the Data Governance Transformation MVP.',
       agent_id,
       'https://mdi.georgetown.edu'
FROM dcat.agent WHERE name = 'Massive Data Institute'
ON CONFLICT DO NOTHING;

INSERT INTO gov.governance_role (name, description, authority_level) VALUES
  ('Program Data Owner',         'Delegated authority over Program data uses.',           'enterprise'),
  ('Program Database Administrator', 'Lead of Data Governance Team.',                     'program'),
  ('Data Steward',               'Maintains metadata for a unit / business area.',        'program'),
  ('Data Custodian',             'Develops and curates data products.',                   'dataset'),
  ('Embedded IT Liaison',        'Bridges Program and IT.',                               'program')
ON CONFLICT DO NOTHING;

INSERT INTO gov.security_marking (name, classification_level, description) VALUES
  ('Public',         'unrestricted', 'Approved for public release.'),
  ('Internal',       'controlled',   'Internal agency use only.'),
  ('Restricted-PII', 'sensitive',    'Contains personally identifiable information.')
ON CONFLICT DO NOTHING;

INSERT INTO gov.policy (name, policy_type, authority, summary, effective_date, review_cycle_days) VALUES
  ('Default Privacy Policy',      'privacy',       'Privacy Act',  'Baseline privacy controls.',  '2026-01-01', 365),
  ('Default Retention Policy',    'retention',     'NARA',         'Default retention schedule.', '2026-01-01', 730)
ON CONFLICT DO NOTHING;
