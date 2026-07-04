#!/usr/bin/env bash
# seed-vector-demo.sh — populate the V-04 Vector Surveillance dashboard with a
# realistic, self-contained Indonesian example dataset so it is reviewable and
# demo-ready out of the box.
#
# The stock catalog carries no vector pools/results, so this seed creates the
# WHOLE scenario itself (sample type → species → sites → tests +
# significance-classified results → samples → pools → identifications → analyses
# → results) — it is self-contained and needs no catalog changes. Positivity is
# catalog-driven via test_result.significance, which is metadata (no
# transaction-REST path), so this seeds via `docker exec psql` against the
# running stack rather than REST.
#
# Scenario (Indonesia): 6 mosquito species across 5 surveillance sites and
# 4 pathogen assays, ~70 pools over 10 ISO weeks, with per-site/per-week
# variation so every dashboard panel is populated:
#   - malaria + sporozoite (CSP-ELISA) surveillance of Anopheles in eastern
#     Indonesia (Kupang/NTT, Jayapura/Papua);
#   - dengue surveillance of Aedes in urban Java/Bali (Jakarta, Surabaya,
#     Denpasar); Japanese encephalitis surveillance of Culex (Denpasar).
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
DELETE FROM clinlims.analysis_qaevent      WHERE id >= ${BASE};
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
DELETE FROM clinlims.organization         WHERE id >= ${BASE};
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
  qae_catalog int;   -- an existing QA_EVENT to attach QC failures to (may be null)
  -- species (Indonesian mosquito vectors)
  sp_sund  int := b + 1;  -- Anopheles sundaicus   (coastal malaria)
  sp_macu  int := b + 2;  -- Anopheles maculatus   (hill/forest malaria)
  sp_fara  int := b + 3;  -- Anopheles farauti     (eastern Indonesia malaria)
  sp_aeae  int := b + 4;  -- Aedes aegypti         (dengue, urban)
  sp_aeal  int := b + 5;  -- Aedes albopictus      (dengue, peri-urban)
  sp_culx  int := b + 6;  -- Culex quinquefasciatus (JE / filariasis)
  -- sites (Indonesian surveillance locations)
  site_kpg int := b + 10; -- Kupang, NTT      (malaria)
  site_jyp int := b + 11; -- Jayapura, Papua  (malaria)
  site_jkt int := b + 12; -- Jakarta Utara    (dengue)
  site_sby int := b + 13; -- Surabaya         (dengue)
  site_dps int := b + 14; -- Denpasar, Bali   (dengue / JE)
  -- tests
  t_mal    int := b + 20; -- Malaria Parasite Detection
  t_csp    int := b + 21; -- Pan-Plasmodium CSP ELISA (sporozoite, LOINC 71712-2)
  t_den    int := b + 22; -- Dengue Virus Detection
  t_jev    int := b + 23; -- Japanese Encephalitis Virus Detection
  -- test_results (significance classifications)
  tr_mal_p int := b + 30; tr_mal_n int := b + 31;
  tr_csp_p int := b + 32; tr_csp_n int := b + 33;
  tr_den_p int := b + 34; tr_den_n int := b + 35;
  tr_jev_p int := b + 36; tr_jev_n int := b + 37;
  lane record;
  w        int;
  off      int;
  is_pos   boolean;
  trid     int;
  decon    text;
  cdate    date;
  qty      int;
  sid int; itm int; pid int; aid int; rid int; trv text;
  r_itm int; r_aid int;
  qc_k int := 0;
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

  -- An existing catalog QA event, reused to mark a few analyses as QC failures.
  SELECT id INTO qae_catalog FROM clinlims.qa_event ORDER BY id LIMIT 1;

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
    (sp_sund, 'Anopheles', 'sundaicus',        b, true, 1, now()),
    (sp_macu, 'Anopheles', 'maculatus',        b, true, 1, now()),
    (sp_fara, 'Anopheles', 'farauti',          b, true, 1, now()),
    (sp_aeae, 'Aedes',     'aegypti',          b, true, 1, now()),
    (sp_aeal, 'Aedes',     'albopictus',       b, true, 1, now()),
    (sp_culx, 'Culex',     'quinquefasciatus', b, true, 1, now());

  INSERT INTO clinlims.vector_sampling_site(id, code, name, active, sys_user_id, lastupdated) VALUES
    (site_kpg, 'KPG',   'Kupang',        true, 1, now()),
    (site_jyp, 'JYP',   'Jayapura',      true, 1, now()),
    (site_jkt, 'JKT-U', 'Jakarta Utara', true, 1, now()),
    (site_sby, 'SBY',   'Surabaya',      true, 1, now()),
    (site_dps, 'DPS',   'Denpasar',      true, 1, now());

  -- Pathogen-detection tests. CSP carries the sporozoite LOINC 71712-2.
  INSERT INTO clinlims.test(id, description, name, guid, loinc, test_section_id, test_format_id,
      orderable, antimicrobial_resistance, sort_order, lastupdated) VALUES
    (t_mal, 'Malaria Parasite Detection',        'Malaria Parasite Detection',        gen_random_uuid()::text, '32700-7', b, fmt, true, false, 1, now()),
    (t_csp, 'Pan-Plasmodium CSP ELISA',          'Pan-Plasmodium CSP ELISA',          gen_random_uuid()::text, '71712-2', b, fmt, true, false, 2, now()),
    (t_den, 'Dengue Virus Detection',            'Dengue Virus Detection',            gen_random_uuid()::text, '32700-8', b, fmt, true, false, 3, now()),
    (t_jev, 'Japanese Encephalitis Virus Detection', 'Japanese Encephalitis Virus Detection', gen_random_uuid()::text, '32700-9', b, fmt, true, false, 4, now());

  -- Significance-classified catalog results (the positivity source of truth).
  INSERT INTO clinlims.test_result(id, test_id, tst_rslt_type, value, significance, is_active, sort_order, lastupdated) VALUES
    (tr_mal_p, t_mal, 'D', 'Detected',     'POSITIVE', true, 1, now()),
    (tr_mal_n, t_mal, 'D', 'Not Detected', 'NEGATIVE', true, 2, now()),
    (tr_csp_p, t_csp, 'D', 'Positive',     'POSITIVE', true, 1, now()),
    (tr_csp_n, t_csp, 'D', 'Negative',     'NEGATIVE', true, 2, now()),
    (tr_den_p, t_den, 'D', 'Detected',     'POSITIVE', true, 1, now()),
    (tr_den_n, t_den, 'D', 'Not Detected', 'NEGATIVE', true, 2, now()),
    (tr_jev_p, t_jev, 'D', 'Detected',     'POSITIVE', true, 1, now()),
    (tr_jev_n, t_jev, 'D', 'Not Detected', 'NEGATIVE', true, 2, now());

  -- ---- Sampling lanes: one pool per (lane × ISO week) over 10 weeks ---------
  -- Each lane is a (site, species, assay) surveillance stream. A pool in week w
  -- is POSITIVE when (w + pos_phase) mod pos_every = 0, which spreads positives
  -- across the series per pathogen; lanes flagged resolve also emit an individual
  -- deconvolution-resolved positive leaf so the observed-organism count has data.
  --   base_qty seeds a per-lane specimen count; a shared seasonal hump + jitter
  --   is added per week so the stacked density trend rises and falls naturally.
  FOR lane IN SELECT * FROM (VALUES
      --  no site      species   assay  tr_pos    tr_neg    base pos_every pos_phase resolve
      (1, site_kpg, sp_sund, t_mal, tr_mal_p, tr_mal_n, 12, 4, 0, true),
      (2, site_kpg, sp_sund, t_csp, tr_csp_p, tr_csp_n, 12, 5, 3, false),
      (3, site_jyp, sp_fara, t_mal, tr_mal_p, tr_mal_n, 10, 4, 1, true),
      (4, site_jyp, sp_macu, t_csp, tr_csp_p, tr_csp_n,  8, 9, 5, false),
      (5, site_jkt, sp_aeae, t_den, tr_den_p, tr_den_n, 14, 3, 1, false),
      (6, site_sby, sp_aeal, t_den, tr_den_p, tr_den_n, 11, 3, 0, false),
      (7, site_dps, sp_culx, t_jev, tr_jev_p, tr_jev_n,  9, 4, 2, false)
    ) AS L(lane_no, site, species, testid, tr_p, tr_n, base_qty, pos_every, pos_phase, resolve)
  LOOP
    FOR w IN 0..9 LOOP
      off    := lane.lane_no * 100 + w;
      is_pos := (lane.pos_every > 0 AND ((w + lane.pos_phase) % lane.pos_every) = 0);
      trid   := CASE WHEN is_pos THEN lane.tr_p ELSE lane.tr_n END;
      -- Negative and resolved-positive pools are COMPLETE; unresolved positives
      -- stay NOT_APPLICABLE. Positivity itself is driven by significance, not this.
      decon  := CASE WHEN is_pos AND NOT lane.resolve THEN 'NOT_APPLICABLE' ELSE 'COMPLETE' END;
      -- 10 contiguous ISO weeks from 2026-04-27 (Mon), staggered within the week.
      cdate  := DATE '2026-04-27' + (w * 7 + (lane.lane_no % 5));
      qty    := lane.base_qty + greatest(0, 5 - abs(w - 5)) + ((lane.lane_no * 2 + w) % 4);

      sid := b + 100000 + off;
      itm := b + 200000 + off;
      pid := b + 300000 + off;
      aid := b + 400000 + off;
      rid := b + 500000 + off;

      INSERT INTO clinlims.sample(id, accession_number, domain, status_id, entered_date,
          received_date, collection_date, revision, is_confirmation, lastupdated)
        VALUES (sid, 'VS-DEMO-' || off, 'V', sample_status, cdate, cdate, cdate, 0, false, now());

      INSERT INTO clinlims.sample_item(id, samp_id, sort_order, status_id, typeosamp_id,
          quantity, collection_location_id, collection_date, voided, lastupdated)
        VALUES (itm, sid, 1, sample_status, b, qty, lane.site, cdate, false, now());

      INSERT INTO clinlims.vector_specimen_identification(id, sample_item_id, vector_species_id,
          identification_method, confidence, identified_by_user_id, lastupdated)
        VALUES (b + 600000 + off, itm, lane.species, 'MORPHOLOGICAL', 'CONFIRMED', 1, now());

      INSERT INTO clinlims.vector_pool(id, sample_id, active, deconvolution_status, external_id, sys_user_id, lastupdated)
        VALUES (pid, sid, true, decon, 'VS-DEMO-' || off, 1, now());
      INSERT INTO clinlims.vector_pool_member(vector_pool_id, sample_item_id, lastupdated)
        VALUES (pid, itm, now());

      SELECT value INTO trv FROM clinlims.test_result WHERE id = trid;
      INSERT INTO clinlims.analysis(id, vector_pool_id, test_id, test_sect_id, analysis_type,
          revision, status_id, status, started_date, entry_date, type_of_sample_name, lastupdated)
        VALUES (aid, pid, lane.testid, b, 'MANUAL', 1, sample_status, '1', cdate, cdate, 'Mosquito', now());
      INSERT INTO clinlims.result(id, analysis_id, analyte_id, test_result_id, sort_order,
          result_type, value, grouping, lastupdated)
        VALUES (rid, aid, b, trid, 1, 'D', trv, 0, now());

      -- Deconvolution-resolved positive: an individual positive leaf so the
      -- deconvolution-aware observed-organism count has something to find.
      IF is_pos AND lane.resolve THEN
        r_itm := b + 700000 + off;
        r_aid := b + 740000 + off;
        INSERT INTO clinlims.sample_item(id, samp_id, sort_order, status_id, typeosamp_id,
            quantity, collection_location_id, collection_date, voided, lastupdated)
          VALUES (r_itm, sid, 2, sample_status, b, 1, lane.site, cdate, false, now());
        INSERT INTO clinlims.vector_specimen_identification(id, sample_item_id, vector_species_id,
            identification_method, confidence, identified_by_user_id, lastupdated)
          VALUES (b + 720000 + off, r_itm, lane.species, 'MOLECULAR', 'CONFIRMED', 1, now());
        INSERT INTO clinlims.analysis(id, sampitem_id, test_id, test_sect_id, analysis_type, revision,
            status_id, status, started_date, entry_date, type_of_sample_name, lastupdated)
          VALUES (r_aid, r_itm, lane.testid, b, 'MANUAL', 1, sample_status, '1', cdate, cdate, 'Mosquito', now());
        INSERT INTO clinlims.result(id, analysis_id, analyte_id, test_result_id, sort_order,
            result_type, value, grouping, lastupdated)
          VALUES (b + 760000 + off, r_aid, b, lane.tr_p, 1, 'D', trv, 0, now());
      END IF;

      -- Sprinkle a few QC failures (a QA event on the pool analysis) so the QC
      -- pass-rate panel reads a believable <100%. Skipped if the catalog has no
      -- QA event to reference.
      IF qae_catalog IS NOT NULL AND qc_k < 3
         AND lane.lane_no IN (3, 5, 6) AND w = (lane.lane_no + 1) THEN
        qc_k := qc_k + 1;
        INSERT INTO clinlims.analysis_qaevent(id, analysis_id, qa_event_id, lastupdated)
          VALUES (b + 800000 + qc_k, aid, qae_catalog, now());
      END IF;
    END LOOP;
  END LOOP;

  RAISE NOTICE 'vector demo seeded: 6 species, 5 sites, 4 assays, 70 pools over 10 weeks (% QC failures)', qc_k;
END \$\$;
SQL

echo "[seed-vector-demo] summary:"
psql -t -A -c "
  SELECT 'pools=' || count(*) FROM clinlims.vector_pool WHERE id >= ${BASE}
  UNION ALL SELECT 'positive_results=' || count(*) FROM clinlims.result r
    JOIN clinlims.test_result tr ON tr.id = r.test_result_id
    WHERE r.id >= ${BASE} AND tr.significance = 'POSITIVE'
  UNION ALL SELECT 'qc_failures=' || count(*) FROM clinlims.analysis_qaevent WHERE id >= ${BASE};"
echo "[seed-vector-demo] done — open /VectorSurveillanceReport and Apply."
