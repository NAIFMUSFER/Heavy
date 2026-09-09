CREATE EXTENSION IF NOT EXISTS postgis;
ALTER TABLE delivery_zones ADD COLUMN geom geometry(Polygon,4326);
CREATE FUNCTION jana_zone_geometry() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.geom := ST_SetSRID(ST_GeomFromGeoJSON(NEW.polygon::text),4326);
  IF NOT ST_IsValid(NEW.geom) OR ST_IsEmpty(NEW.geom) OR ST_Area(NEW.geom) <= 0
     OR ST_XMin(NEW.geom::box3d) < -180 OR ST_XMax(NEW.geom::box3d) > 180
     OR ST_YMin(NEW.geom::box3d) < -90 OR ST_YMax(NEW.geom::box3d) > 90 THEN
    RAISE EXCEPTION 'invalid_delivery_polygon';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER delivery_zone_geometry BEFORE INSERT OR UPDATE OF polygon ON delivery_zones
FOR EACH ROW EXECUTE FUNCTION jana_zone_geometry();
UPDATE delivery_zones SET polygon=polygon;
ALTER TABLE delivery_zones ALTER COLUMN geom SET NOT NULL;
CREATE INDEX ix_delivery_zones_geometry ON delivery_zones USING GIST(geom);
CREATE FUNCTION jana_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'append_only_ledger'; END $$;
CREATE TRIGGER immutable_stock_movements BEFORE UPDATE OR DELETE ON stock_movements FOR EACH ROW EXECUTE FUNCTION jana_append_only();
CREATE TRIGGER immutable_order_events BEFORE UPDATE OR DELETE ON order_events FOR EACH ROW EXECUTE FUNCTION jana_append_only();
CREATE TRIGGER immutable_audit_log BEFORE UPDATE OR DELETE ON audit_log FOR EACH ROW EXECUTE FUNCTION jana_append_only();
CREATE FUNCTION jana_original_order_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.original_snapshot::jsonb IS DISTINCT FROM OLD.original_snapshot::jsonb THEN RAISE EXCEPTION 'immutable_order_original'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER immutable_order_original BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION jana_original_order_immutable();
CREATE FUNCTION jana_offering_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (to_jsonb(NEW)-'active') IS DISTINCT FROM (to_jsonb(OLD)-'active') THEN RAISE EXCEPTION 'create_a_new_offering_version'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER immutable_offering_version BEFORE UPDATE ON offerings FOR EACH ROW EXECUTE FUNCTION jana_offering_immutable();
CREATE FUNCTION jana_stock_unit_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.base_unit IS DISTINCT FROM OLD.base_unit THEN RAISE EXCEPTION 'immutable_stock_base_unit'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER immutable_stock_unit BEFORE UPDATE ON stock_items FOR EACH ROW EXECUTE FUNCTION jana_stock_unit_immutable();