enable_language(C)
include(FetchContent)

FetchContent_Declare(flclash_sqlite
  URL https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip
  URL_HASH SHA256=1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d
)
FetchContent_GetProperties(flclash_sqlite)
if(NOT flclash_sqlite_POPULATED)
  FetchContent_Populate(flclash_sqlite)
endif()

add_library(sqlite3_compat SHARED "${flclash_sqlite_SOURCE_DIR}/sqlite3.c")
set_target_properties(sqlite3_compat PROPERTIES OUTPUT_NAME sqlite3)
target_compile_options(sqlite3_compat PRIVATE -O2)
target_compile_definitions(sqlite3_compat PRIVATE
  SQLITE_ENABLE_DBSTAT_VTAB
  SQLITE_ENABLE_FTS5
  SQLITE_ENABLE_RTREE
  SQLITE_ENABLE_MATH_FUNCTIONS
  SQLITE_ENABLE_SESSION
  SQLITE_ENABLE_PREUPDATE_HOOK
  SQLITE_DQS=0
  SQLITE_DEFAULT_MEMSTATUS=0
  SQLITE_TEMP_STORE=2
  SQLITE_MAX_EXPR_DEPTH=0
  SQLITE_STRICT_SUBTYPE=1
  SQLITE_OMIT_AUTHORIZATION
  SQLITE_OMIT_DECLTYPE
  SQLITE_OMIT_DEPRECATED
  SQLITE_OMIT_PROGRESS_CALLBACK
  SQLITE_OMIT_SHARED_CACHE
  SQLITE_OMIT_TCL_VARIABLE
  SQLITE_OMIT_TRACE
  SQLITE_USE_ALLOCA
  SQLITE_UNTESTABLE
  SQLITE_HAVE_ISNAN
  SQLITE_HAVE_LOCALTIME_R
  SQLITE_HAVE_MALLOC_USABLE_SIZE
  SQLITE_HAVE_STRCHRNUL
)
target_link_options(sqlite3_compat PRIVATE -Wl,-Bsymbolic)
target_link_libraries(sqlite3_compat PRIVATE dl m pthread)
install(TARGETS sqlite3_compat
  LIBRARY DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime
)
