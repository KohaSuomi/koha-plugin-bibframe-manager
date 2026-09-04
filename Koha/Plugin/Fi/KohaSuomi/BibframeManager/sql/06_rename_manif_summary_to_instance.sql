-- Migration for existing installations: rename record_manif_summary to
-- record_instance_summary, reflecting that the LoC BIBFRAME 3-level model
-- (Work -> Instance -> Item) is the canonical stored model.
-- Also renames the manifestation_type column to instance_type.
--
-- This runs BEFORE 02_summary_tables.sql during upgrade(). On a fresh install
-- 02 creates record_instance_summary directly and 06 is not run.

RENAME TABLE `record_manif_summary` TO `record_instance_summary`;

ALTER TABLE `record_instance_summary`
    CHANGE COLUMN `manifestation_type` `instance_type` VARCHAR(128) NULL;

ALTER TABLE `record_work_summary`
    CHANGE COLUMN `manifestation_count` `instance_count` INT UNSIGNED DEFAULT 0;
