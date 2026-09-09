CREATE TABLE slot_templates (
    id varchar(36) PRIMARY KEY,
    zone_id varchar(36) NOT NULL REFERENCES delivery_zones(id),
    name varchar(100) NOT NULL,
    weekday integer NOT NULL CHECK (weekday BETWEEN 0 AND 6),
    start_minute integer NOT NULL CHECK (start_minute >= 0 AND start_minute < 1440),
    end_minute integer NOT NULL CHECK (end_minute > start_minute AND end_minute <= 1440),
    cutoff_minutes integer NOT NULL DEFAULT 180 CHECK (cutoff_minutes >= 0 AND cutoff_minutes <= 10080),
    capacity integer NOT NULL CHECK (capacity > 0),
    active boolean NOT NULL DEFAULT true,
    created_at bigint NOT NULL,
    CONSTRAINT slot_template_unique UNIQUE(zone_id, weekday, start_minute, end_minute)
);
CREATE INDEX slot_templates_zone_active_idx ON slot_templates(zone_id, active);
ALTER TABLE tickets ADD COLUMN priority varchar(12) NOT NULL DEFAULT 'normal';
ALTER TABLE tickets ADD COLUMN assigned_to varchar(36) NULL REFERENCES users(id);
ALTER TABLE tickets ADD COLUMN updated_at bigint;
UPDATE tickets SET updated_at = created_at WHERE updated_at IS NULL;
ALTER TABLE tickets ALTER COLUMN updated_at SET NOT NULL;
ALTER TABLE tickets ADD CONSTRAINT ticket_state CHECK (state IN ('open','closed'));
ALTER TABLE tickets ADD CONSTRAINT ticket_priority CHECK (priority IN ('low','normal','high','urgent'));
CREATE INDEX tickets_priority_idx ON tickets(priority);
CREATE INDEX tickets_assigned_to_idx ON tickets(assigned_to);
CREATE INDEX tickets_updated_at_idx ON tickets(updated_at);