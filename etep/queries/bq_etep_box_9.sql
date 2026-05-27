-- bq_etep_box_9 -- Maryland 2034 W2 records from pseudopeople.
-- Source pseudopeople.taxes_w2_and_1099 confirmed present on 2026-05-14.

CREATE OR REPLACE TABLE `mdi-governance.etep.bq_etep_box_9` AS
SELECT *
FROM `mdi-governance.pseudopeople.taxes_w2_and_1099`
WHERE state    = 'MD'
  AND tax_year = 2034
  AND tax_form = 'W2';
