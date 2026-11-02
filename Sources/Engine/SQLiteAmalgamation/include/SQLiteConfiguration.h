#ifndef BRAUS_SQLITE_CONFIGURATION_H
#define BRAUS_SQLITE_CONFIGURATION_H

#include "sqlite3.h"

// Give Swift a fixed signature for SQLite's variadic connection configuration API.
static inline int braus_sqlite_no_checkpoint_on_close(sqlite3 *database, int enabled, int *current) {
    return sqlite3_db_config(database, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, enabled, current);
}

#endif
