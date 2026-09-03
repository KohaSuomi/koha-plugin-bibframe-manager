-- Migration for existing installations adding item_id column to record_resources
-- Items link to Koha's items table (authoritative) via item_id

ALTER TABLE record_resources
    ADD COLUMN item_id BIGINT UNSIGNED NULL AFTER biblio_id,
    ADD KEY idx_record_resources_item_id (item_id);
