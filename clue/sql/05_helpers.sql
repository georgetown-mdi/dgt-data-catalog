-- Helper Functions for CLUE Data Processing
-- These functions handle data transformation and safe parsing

SET search_path TO clue, public;

-- Function to safely parse dates
CREATE OR REPLACE FUNCTION clue.safe_to_date(date_str TEXT, format TEXT)
RETURNS DATE AS $$
BEGIN
    IF date_str IS NULL OR date_str = '' OR date_str = 'NA' THEN
        RETURN NULL;
    END IF;
    RETURN TO_DATE(date_str, format);
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to safely parse JSON
CREATE OR REPLACE FUNCTION clue.safe_json(text_str TEXT)
RETURNS JSONB AS $$
BEGIN
    IF text_str IS NULL OR text_str = '' OR text_str = 'NA' THEN
        RETURN NULL;
    END IF;
    RETURN text_str::jsonb;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to convert 'NA' strings to NULL
CREATE OR REPLACE FUNCTION clue.nullif_na(text_str TEXT)
RETURNS TEXT AS $$
BEGIN
    IF text_str = 'NA' OR text_str = '' THEN
        RETURN NULL;
    END IF;
    RETURN text_str;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to extract court name from filename
CREATE OR REPLACE FUNCTION clue.extract_court_from_filename(filename TEXT)
RETURNS TEXT AS $$
DECLARE
    court_name TEXT;
BEGIN
    -- Extract pattern like "Allegany County Circuit Court" from filename
    court_name := regexp_replace(filename, '^.*_([A-Za-z\s]+County[A-Za-z\s]+Court)\.csv$', '\1');
    IF court_name = filename THEN
        RETURN 'Unknown Court';
    END IF;
    RETURN court_name;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to calculate MD5 hash of a file (for duplicate detection)
CREATE OR REPLACE FUNCTION clue.calculate_file_hash(content TEXT)
RETURNS TEXT AS $$
BEGIN
    RETURN md5(content);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

COMMENT ON FUNCTION clue.safe_to_date IS 'Safely parse date strings, returns NULL on error';
COMMENT ON FUNCTION clue.safe_json IS 'Safely parse JSON strings, returns NULL on error';
COMMENT ON FUNCTION clue.nullif_na IS 'Convert NA strings to NULL';
COMMENT ON FUNCTION clue.extract_court_from_filename IS 'Extract court name from CSV filename';
