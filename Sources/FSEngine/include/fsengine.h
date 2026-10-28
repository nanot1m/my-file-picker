#ifndef FSENGINE_H
#define FSENGINE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    FSE_DIR     = 1u << 0,
    FSE_SYMLINK = 1u << 1,
    FSE_HIDDEN  = 1u << 2,
};

typedef struct {
    uint32_t name_off;   /* byte offset into fse_dir.arena, NUL-terminated */
    uint16_t name_len;   /* bytes, excluding NUL */
    uint16_t flags;      /* FSE_* */
    uint64_t size;
    int64_t  mtime;      /* seconds since epoch */
} fse_entry;

typedef struct {
    fse_entry *entries;  /* directories first, then files; each group sorted by name */
    uint32_t   count;
    uint32_t   dir_count;
    char      *arena;
    uint32_t   arena_len;
    uint32_t   arena_cap;
    uint32_t   cap;
    uint64_t   read_ns;  /* wall time of the enumeration, excluding sort */
    uint64_t   sort_ns;
} fse_dir;

typedef struct {
    int include_hidden;  /* include dotfiles and UF_HIDDEN entries */
} fse_options;

/* Enumerates one directory level. Returns NULL and sets *err to an errno value on failure. */
fse_dir *fse_dir_read(const char *path, const fse_options *opts, int *err);
void fse_dir_free(fse_dir *d);

static inline const char *fse_entry_name(const fse_dir *d, uint32_t i) {
    return d->arena + d->entries[i].name_off;
}

size_t fse_dir_memory(const fse_dir *d);

/* Case-insensitive, digit-run-aware ordering used for sorting. */
int fse_name_compare(const char *a, const char *b);

uint64_t fse_now_ns(void);

#ifdef __cplusplus
}
#endif
#endif
