-- Allow "credential" events (a device's claim about itself, e.g. finished
-- training; issue #58). Idempotent: drops and re-adds the kind check under a
-- fixed name, whatever name PostgreSQL gave the original inline CHECK.
DO $$
DECLARE
    old_name TEXT;
BEGIN
    FOR old_name IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'events'::regclass AND contype = 'c'
          AND pg_get_constraintdef(oid) LIKE '%kind%'
    LOOP
        EXECUTE format('ALTER TABLE events DROP CONSTRAINT %I', old_name);
    END LOOP;
    ALTER TABLE events ADD CONSTRAINT events_kind_check
        CHECK (kind IN ('report', 'vote', 'credential'));
END $$;
