-- CLUE Maryland Court Data Schema
-- This schema supports ingesting multiple CSV files from different counties/courts
-- Database: governance_catalog

-- (caller already connected to governance_catalog and ensured the clue schema exists)

CREATE SCHEMA IF NOT EXISTS clue;

-- Set search path
SET search_path TO clue, public;

-- Metadata table to track loaded files
CREATE TABLE IF NOT EXISTS clue.file_load_metadata (
    load_id SERIAL PRIMARY KEY,
    file_name TEXT NOT NULL UNIQUE,
    file_path TEXT,
    file_size_bytes BIGINT,
    rows_loaded INTEGER,
    load_started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    load_completed_at TIMESTAMP,
    load_status TEXT CHECK (load_status IN ('started', 'completed', 'failed')),
    error_message TEXT,
    file_hash TEXT,
    court_name TEXT,
    data_date DATE
);

-- Case types lookup table (single reference table)
CREATE TABLE IF NOT EXISTS clue.case_types (
    case_count INTEGER,
    case_type TEXT,
    subtype TEXT,
    notes TEXT,
    col5 TEXT,
    col6 TEXT,
    col7 TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (case_type, subtype)
);

-- Source data table - stores raw data from all CSV files
CREATE TABLE IF NOT EXISTS clue.source_data (
    source_id BIGSERIAL PRIMARY KEY,
    load_id INTEGER REFERENCES clue.file_load_metadata(load_id),
    row_num TEXT,
    id TEXT,
    case_number TEXT,
    caption TEXT,
    name TEXT,
    dob TEXT,
    party_type TEXT,
    court TEXT,
    court_id TEXT,
    case_type TEXT,
    filing_date TEXT,
    status TEXT,
    court_system TEXT,
    checksum TEXT,
    misc TEXT,
    last_scrape TEXT,
    not_found_at TEXT,
    created_at TEXT,
    updated_at TEXT,
    tracking_number TEXT,
    case_type_code TEXT,
    location TEXT,
    defendant TEXT,
    plaintiff TEXT,
    error TEXT,
    versions TEXT,
    parser TEXT,
    cjis TEXT,
    sentence_length TEXT,
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Final processed tables
CREATE TABLE IF NOT EXISTS clue.cases (
    row_id BIGINT PRIMARY KEY,
    source_id BIGINT REFERENCES clue.source_data(source_id),
    case_number TEXT,
    caption TEXT,
    name TEXT,
    birth_date TEXT,
    role TEXT,
    court TEXT,
    case_type TEXT,
    file_date DATE,
    case_status TEXT,
    court_system TEXT,
    create_date TEXT,
    update_date TEXT,
    court_location TEXT,
    versions TEXT,
    category TEXT,
    processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS clue.defendants (
    defendant_id BIGSERIAL PRIMARY KEY,
    row_id BIGINT,
    name TEXT,
    city TEXT,
    state TEXT,
    zip TEXT,
    address TEXT,
    address_ln1 TEXT,
    address_ln2 TEXT,
    party_num TEXT,
    role TEXT,
    org_name TEXT,
    removal_date DATE,
    processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (row_id) REFERENCES clue.cases(row_id)
);

CREATE TABLE IF NOT EXISTS clue.plaintiffs (
    plaintiff_id BIGSERIAL PRIMARY KEY,
    row_id BIGINT,
    name TEXT,
    city TEXT,
    state TEXT,
    zip TEXT,
    address TEXT,
    address_ln1 TEXT,
    address_ln2 TEXT,
    party_num TEXT,
    role TEXT,
    org_name TEXT,
    removal_date DATE,
    processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (row_id) REFERENCES clue.cases(row_id)
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_source_data_load_id ON clue.source_data(load_id);
CREATE INDEX IF NOT EXISTS idx_source_data_id ON clue.source_data(id);
CREATE INDEX IF NOT EXISTS idx_source_data_case_type ON clue.source_data(case_type);
CREATE INDEX IF NOT EXISTS idx_source_data_court ON clue.source_data(court);
CREATE INDEX IF NOT EXISTS idx_case_types_lookup ON clue.case_types(case_type);
CREATE INDEX IF NOT EXISTS idx_cases_category ON clue.cases(category);
CREATE INDEX IF NOT EXISTS idx_cases_court ON clue.cases(court);
CREATE INDEX IF NOT EXISTS idx_cases_file_date ON clue.cases(file_date);
CREATE INDEX IF NOT EXISTS idx_defendants_row_id ON clue.defendants(row_id);
CREATE INDEX IF NOT EXISTS idx_plaintiffs_row_id ON clue.plaintiffs(row_id);

-- (No external GRANTs — governance_admin owns this schema in DGT-next.)

COMMENT ON SCHEMA clue IS 'Maryland CLUE court case data';
COMMENT ON TABLE clue.file_load_metadata IS 'Tracks all CSV files loaded into the system';
COMMENT ON TABLE clue.source_data IS 'Raw data from CSV files - supports multiple counties';
COMMENT ON TABLE clue.cases IS 'Processed and categorized court cases';
COMMENT ON TABLE clue.defendants IS 'Defendant information extracted from JSON';
COMMENT ON TABLE clue.plaintiffs IS 'Plaintiff information extracted from JSON';
