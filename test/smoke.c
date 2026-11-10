#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tidesdb/db.h>

/*
 * usage: smoke <db-dir> <snappy 0|1> <lz4 0|1> <zstd 0|1>
 * Checks that the compiled-in compression backends match what the build asked for, then writes,
 * flushes and reads back a compressible value through each available one.
 */

#define CHECK(x) do { int rc_ = (x); if (rc_ != TDB_SUCCESS) { fprintf(stderr, "%s failed: %d\n", #x, rc_); return 1; } } while (0)

static int roundtrip(tidesdb_t *db, const char *name, int algo)
{
    tidesdb_column_family_config_t cf_cfg = tidesdb_default_column_family_config();
    cf_cfg.encoding_pipeline[0] = (uint8_t)algo;
    cf_cfg.encoding_count = algo == TDB_COMPRESS_NONE ? 0 : 1;
    /* the directory persists in the build cache across runs */
    int rc = tidesdb_create_column_family(db, name, &cf_cfg);
    if (rc != TDB_SUCCESS && rc != TDB_ERR_EXISTS) { fprintf(stderr, "create %s failed: %d\n", name, rc); return 1; }
    tidesdb_column_family_t *cf = tidesdb_get_column_family(db, name);
    if (!cf) return 1;

    static uint8_t value[4096];
    memset(value, 'a', sizeof value);

    tidesdb_txn_t *txn = NULL;
    CHECK(tidesdb_txn_begin(db, &txn));
    CHECK(tidesdb_txn_put(txn, cf, (const uint8_t *)"k", 1, value, sizeof value, 0));
    CHECK(tidesdb_txn_commit(txn));
    tidesdb_txn_free(txn);
    CHECK(tidesdb_flush_memtable(db)); /* force the value through the encoding pipeline */

    CHECK(tidesdb_txn_begin(db, &txn));
    uint8_t *val = NULL; size_t len = 0;
    CHECK(tidesdb_txn_get(txn, cf, (const uint8_t *)"k", 1, &val, &len));
    int ok = len == sizeof value && memcmp(val, value, len) == 0;
    free(val);
    tidesdb_txn_free(txn);
    if (!ok) fprintf(stderr, "%s: value mismatch\n", name);
    return ok ? 0 : 1;
}

int main(int argc, char **argv)
{
    if (argc < 5) return 1;
    const struct { const char *name; int algo; int expect; } algos[] = {
        { "none", TDB_COMPRESS_NONE, 1 },
        { "snappy", TDB_COMPRESS_SNAPPY, atoi(argv[2]) },
        { "lz4", TDB_COMPRESS_LZ4, atoi(argv[3]) },
        { "zstd", TDB_COMPRESS_ZSTD, atoi(argv[4]) },
    };

    for (size_t i = 0; i < sizeof algos / sizeof *algos; i++) {
        int have = tidesdb_compression_available(algos[i].algo) != 0;
        if (have != algos[i].expect) {
            fprintf(stderr, "%s: available=%d, expected %d\n", algos[i].name, have, algos[i].expect);
            return 1;
        }
    }

    tidesdb_config_t cfg = tidesdb_default_config();
    cfg.db_path = argv[1];
    tidesdb_t *db = NULL;
    CHECK(tidesdb_open(&cfg, &db));
    for (size_t i = 0; i < sizeof algos / sizeof *algos; i++) {
        if (!algos[i].expect) continue;
        if (roundtrip(db, algos[i].name, algos[i].algo)) return 1;
    }
    CHECK(tidesdb_close(db));
    return 0;
}
