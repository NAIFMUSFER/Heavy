revoke all privileges on table public.spatial_ref_sys from anon, authenticated;
-- Keep PostGIS metadata owned by the database owner; client roles do not need direct access.