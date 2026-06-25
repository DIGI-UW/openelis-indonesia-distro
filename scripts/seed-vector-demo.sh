#!/usr/bin/env bash
# seed-vector-demo.sh — populate the V-04 Vector Surveillance dashboard with a
# realistic, self-contained example dataset so it is reviewable out of the box.
#
# The stock catalog carries no vector pools/results, so this seed creates the
# WHOLE scenario itself (sample type → species → sites → tests +
# significance-classified results → samples → pools → identifications → analyses
# → results) — it is self-contained and needs no catalog changes. Positivity is
# catalog-driven via test_result.significance, which is metadata (no
# transaction-REST path), so this seeds via `docker exec psql` against the
# running stack rather than REST.
#
# Usage:
#   ./scripts/seed-vector-demo.sh           # seed (idempotent; skips if present)
#   ./scripts/seed-vector-demo.sh --clean   # remove the demo rows, then re-seed
#
# Env: DB_CONTAINER (default openelisglobal-database).
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-openelisglobal-database}"
CLEAN="no"
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN="yes" ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

psql() { docker exec -i "$DB_CONTAINER" psql -U clinlims -d clinlims "$@"; }

# All demo rows live in a high, dedicated id range so --clean is a clean sweep
# and real sequence-allocated ids never collide with them.
BASE=970000

if [[ "$CLEAN" == "yes" ]]; then
  echo "[seed-vector-demo] removing prior demo rows (id >= ${BASE})…"
  psql -v ON_ERROR_STOP=0 -q <<SQL || true
DELETE FROM clinlims.result               WHERE id >= ${BASE};
DELETE FROM clinlims.analysis             WHERE id >= ${BASE};
DELETE FROM clinlims.test_result          WHERE id >= ${BASE};
DELETE FROM clinlims.vector_pool_member   WHERE vector_pool_id >= ${BASE};
DELETE FROM clinlims.vector_pool          WHERE id >= ${BASE};
DELETE FROM clinlims.vector_specimen_identification WHERE id >= ${BASE};
DELETE FROM clinlims.sample_item          WHERE id >= ${BASE};
DELETE FROM clinlims.sample               WHERE id >= ${BASE};
DELETE FROM clinlims.vector_sampling_site WHERE id >= ${BASE};
DELETE FROM clinlims.vector_species       WHERE id >= ${BASE};
DELETE FROM clinlims.test                 WHERE id >= ${BASE};
DELETE FROM clinlims.test_section         WHERE id >= ${BASE};
DELETE FROM clinlims.type_of_sample       WHERE id >= ${BASE};
DELETE FROM clinlims.analyte              WHERE id >= ${BASE};
DELETE FROM clinlims.localization_value   WHERE id >= ${BASE};
DELETE FROM clinlims.localization         WHERE id >= ${BASE};
SQL
fi

echo "[seed-vector-demo] seeding into ${DB_CONTAINER}…"
psql -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$
DECLARE
  b         bigint := ${BASE};
  sample_status int;
  fmt       int;
  -- species
  sp_anoph  int := b + 1;  -- Anopheles gambiae
  sp_aedes  int := b + 2;  -- Aedes aegypti
  sp_culex  int := b + 3;  -- Culex quinquefasciatus
  -- sites
  site_a    int := b + 10;
  site_b    int := b + 11;
  -- tests
  t_mal     int := b + 20;  -- Malaria Parasite Detection
  t_csp     int := b + 21;  -- Pan-Plasmodium CSP ELISA (sporozoite, LOINC 71712-2)
  t_den     int := b + 22;  -- Dengue Virus Detection
  -- test_results (significance classifications)
  tr_mal_p  int := b + 30; tr_mal_n int := b + 31;
  tr_csp_p  int := b + 32; tr_csp_n int := b + 33;
  tr_den_p  int := b + 34; tr_den_n int := b + 35;
  rec record;
  sid int; itm int; pid int; aid int; rid int; trv text;
BEGIN
  IF EXISTS (SELECT 1 FROM clinlims.test WHERE id = t_mal) THEN
    RAISE NOTICE 'vector demo already present — skipping (use --clean to reseed)';
    RETURN;
  END IF;

  SELECT id INTO sample_status FROM clinlims.status_of_sample
    WHERE status_type = 'SAMPLE' ORDER BY id LIMIT 1;

  -- A test_format is required by test rows; reuse one if present, else make ours.
  SELECT id INTO fmt FROM clinlims.test_formats LIMIT 1;
  IF fmt IS NULL THEN
    fmt := b;
    INSERT INTO clinlims.test_formats(id, lastupdated) VALUES (b, now());
  END IF;

  -- Owning organization for the vector test section.
  INSERT INTO clinlims.organization(id, name, short_name, local_abbrev, code, lastupdated)
    VALUES (b, 'Vector Surveillance Lab', 'VSL', 'vlab', 'VS900', now());

  -- Localized "Mosquito" label for the sample type.
  INSERT INTO clinlims.localization(id, description) VALUES (b, 'VectorDemoMosquito');
  INSERT INTO clinlims.localization_value(id, localization_id, locale, value)
    VALUES (b, b, 'en', 'Mosquito');

  INSERT INTO clinlims.type_of_sample(id, description, domain, local_abbrev, is_active,
      sort_order, name_localization_id, display_key, lastupdated)
    VALUES (b, 'Mosquito', 'V', 'mosq', true, 1, b, 'sample.type.Mosquito', now());

  INSERT INTO clinlims.analyte(id, analyte_id, name, local_abbrev, lastupdated)
    VALUES (b, b, 'VectorPathogen', 'VPATH', now());

  INSERT INTO clinlims.test_section(id, name, description, org_id, is_external, sort_order,
      name_localization_id, display_key, domain, lastupdated)
    VALUES (b, 'V-04', 'Vector Surveillance', b, 'N', 1, b, 'testSection.V04', 'VECTOR', now());

  -- Species (each tied to the Mosquito sample type).
  INSERT INTO clinlims.vector_species(id, genus, species, sample_type_id, active, sys_user_id, lastupdated) VALUES
    (sp_anoph, 'Anopheles', 'gambiae',          b, true, 1, now()),
    (sp_aedes, 'Aedes',     'aegypti',          b, true, 1, now()),
    (sp_culex, 'Culex',     'quinquefasciatus', b, true, 1, now());

  INSERT INTO clinlims.vector_sampling_site(id, code, name, active, sys_user_id, lastupdated) VALUES
    (site_a, 'SITE-A', 'Antananarivo North', true, 1, now()),
    (site_b, 'SITE-B', 'Toamasina Coast',    true, 1, now());

  -- Pathogen-detection tests. CSP carries the sporozoite LOINC 71712-2.
  INSERT INTO clinlims.test(id, description, name, guid, loinc, test_section_id, test_format_id,
      orderable, antimicrobial_resistance, sort_order, lastupdated) VALUES
    (t_mal, 'Malaria Parasite Detection', 'Malaria Parasite Detection', gen_random_uuid()::text, '32700-7', b, fmt, true, false, 1, now()),
    (t_csp, 'Pan-Plasmodium CSP ELISA',  'Pan-Plasmodium CSP ELISA',   gen_random_uuid()::text, '71712-2', b, fmt, true, false, 2, now()),
    (t_den, 'Dengue Virus Detection',    'Dengue Virus Detection',     gen_random_uuid()::text, '32700-8', b, fmt, true, false, 3, now());

  -- Significance-classified catalog results (the positivity source of truth).
  INSERT INTO clinlims.test_result(id, test_id, tst_rslt_type, value, significance, is_active, sort_order, lastupdated) VALUES
    (tr_mal_p, t_mal, 'D', 'Detected',     'POSITIVE', true, 1, now()),
    (tr_mal_n, t_mal, 'D', 'Not Detected', 'NEGATIVE', true, 2, now()),
    (tr_csp_p, t_csp, 'D', 'Positive',     'POSITIVE', true, 1, now()),
    (tr_csp_n, t_csp, 'D', 'Negative',     'NEGATIVE', true, 2, now()),
    (tr_den_p, t_den, 'D', 'Detected',     'POSITIVE', true, 1, now()),
    (tr_den_n, t_den, 'D', 'Not Detected', 'NEGATIVE', true, 2, now());

  -- ---- Pools across 2 ISO weeks × 2 sites × 3 species --------------------
  -- Each row: (pool offset, species, site, collect date, decon status,
  --            pathogen test, classified result, quantity).
  FOR rec IN SELECT * FROM (VALUES
      -- Anopheles @ Site A, week 1: confirmed-negative, then a resolved positive.
      (100, sp_anoph, site_a, DATE '2026-07-06', 'COMPLETE',        t_mal, tr_mal_n, 10),
      (101, sp_anoph, site_a, DATE '2026-07-06', 'COMPLETE',        t_mal, tr_mal_p, 10),
      -- Anopheles @ Site A, week 1: CSP-ELISA positive (sporozoite signal).
      (102, sp_anoph, site_a, DATE '2026-07-06', 'NOT_APPLICABLE',  t_csp, tr_csp_p, 8),
      -- Aedes @ Site B, week 1: two Dengue-positive pools + one negative.
      (103, sp_aedes, site_b, DATE '2026-07-07', 'NOT_APPLICABLE',  t_den, tr_den_p, 12),
      (104, sp_aedes, site_b, DATE '2026-07-07', 'NOT_APPLICABLE',  t_den, tr_den_p, 9),
      (105, sp_aedes, site_b, DATE '2026-07-07', 'COMPLETE',        t_den, tr_den_n, 11),
      -- Culex @ Site B, week 1: malaria-tested, negative (cross-species guard).
      (106, sp_culex, site_b, DATE '2026-07-08', 'NOT_APPLICABLE',  t_mal, tr_mal_n, 5),
      -- Anopheles @ Site A, week 2: another malaria positive (density trend).
      (107, sp_anoph, site_a, DATE '2026-07-13', 'NOT_APPLICABLE',  t_mal, tr_mal_p, 10)
    ) AS v(off, species, site, cdate, decon, testid, trid, qty)
  LOOP
    sid := b + 200 + rec.off;
    itm := b + 400 + rec.off;
    pid := b + 600 + rec.off;
    aid := b + 800 + rec.off;
    rid := b + 1000 + rec.off;

    INSERT INTO clinlims.sample(id, accession_number, domain, status_id, entered_date,
        received_date, collection_date, revision, is_confirmation, lastupdated)
      VALUES (sid, 'VS-DEMO-' || rec.off, 'V', sample_status, rec.cdate, rec.cdate, rec.cdate, 0, false, now());

    INSERT INTO clinlims.sample_item(id, samp_id, sort_order, status_id, typeosamp_id,
        quantity, collection_location_id, collection_date, voided, lastupdated)
      VALUES (itm, sid, 1, sample_status, b, rec.qty, rec.site, rec.cdate, false, now());

    INSERT INTO clinlims.vector_specimen_identification(id, sample_item_id, vector_species_id,
        identification_method, confidence, identified_by_user_id, lastupdated)
      VALUES (b + 1200 + rec.off, itm, rec.species, 'MORPHOLOGICAL', 'CONFIRMED', 1, now());

    INSERT INTO clinlims.vector_pool(id, sample_id, active, deconvolution_status, external_id, sys_user_id, lastupdated)
      VALUES (pid, sid, true, rec.decon, 'VS-DEMO-' || rec.off, 1, now());
    INSERT INTO clinlims.vector_pool_member(vector_pool_id, sample_item_id, lastupdated)
      VALUES (pid, itm, now());

    SELECT value INTO trv FROM clinlims.test_result WHERE id = rec.trid;
    INSERT INTO clinlims.analysis(id, vector_pool_id, test_id, test_sect_id, analysis_type,
        revision, status_id, status, started_date, entry_date, type_of_sample_name, lastupdated)
      VALUES (aid, pid, rec.testid, b, 'MANUAL', 1, sample_status, '1', rec.cdate, rec.cdate, 'Mosquito', now());
    INSERT INTO clinlims.result(id, analysis_id, analyte_id, test_result_id, sort_order,
        result_type, value, grouping, lastupdated)
      VALUES (rid, aid, b, rec.trid, 1, 'D', trv, 0, now());
  END LOOP;

  -- Resolved Anopheles positive (pool 101): an individual positive leaf so the
  -- deconvolution-aware observed-organism count has something to find.
  INSERT INTO clinlims.sample_item(id, samp_id, sort_order, status_id, typeosamp_id,
      quantity, collection_location_id, collection_date, voided, lastupdated)
    VALUES (b + 1500, b + 301, 2, sample_status, b, 1, site_a, DATE '2026-07-06', false, now());
  INSERT INTO clinlims.vector_specimen_identification(id, sample_item_id, vector_species_id,
      identification_method, confidence, identified_by_user_id, lastupdated)
    VALUES (b + 1501, b + 1500, sp_anoph, 'MOLECULAR', 'CONFIRMED', 1, now());
  INSERT INTO clinlims.analysis(id, sampitem_id, test_id, test_sect_id, analysis_type, revision,
      status_id, status, started_date, entry_date, type_of_sample_name, lastupdated)
    VALUES (b + 1502, b + 1500, t_mal, b, 'MANUAL', 1, sample_status, '1', DATE '2026-07-06', DATE '2026-07-06', 'Mosquito', now());
  INSERT INTO clinlims.result(id, analysis_id, analyte_id, test_result_id, sort_order,
      result_type, value, grouping, lastupdated)
    VALUES (b + 1503, b + 1502, b, tr_mal_p, 1, 'D', 'Detected', 0, now());

  RAISE NOTICE 'vector demo seeded: 3 species, 2 sites, 3 tests, 8 pools + 1 resolved leaf';
END \$\$;
SQL

echo "[seed-vector-demo] summary:"
psql -t -A -c "
  SELECT 'pools=' || count(*) FROM clinlims.vector_pool WHERE id >= ${BASE}
  UNION ALL SELECT 'positive_results=' || count(*) FROM clinlims.result r
    JOIN clinlims.test_result tr ON tr.id = r.test_result_id
    WHERE r.id >= ${BASE} AND tr.significance = 'POSITIVE';"
echo "[seed-vector-demo] done — open /VectorSurveillanceReport and Apply."
